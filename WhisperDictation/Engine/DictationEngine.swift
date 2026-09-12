import Foundation
import Observation
import Cocoa

enum DictationState: String {
    case idle
    case recording
    case processing
    case typing
}

@Observable
final class DictationEngine {
    private(set) var state: DictationState = .idle
    private(set) var lastTranscription: String = ""
    private(set) var isModelLoaded: Bool = false
    private(set) var modelLoadError: String?

    /// Last transcription/recording failure surfaced to the user (inference failure,
    /// audio input configuration change). Cleared when a new recording starts and on
    /// the next successful dictation.
    private(set) var transcriptionError: String?

    /// True while the user is holding the hotkey but the toggle-mode threshold hasn't yet fired.
    /// Also true in the sliver after key-down before the mic is actually live.
    /// Drives the orange Hold island.
    private(set) var isHoldingForToggle: Bool = false

    /// Smoothed per-bar mic energy while recording. Drives the live island meter.
    private(set) var inputLevels: [Float] = Array(repeating: 0, count: AudioCapture.visualizerBars)

    var isAutoHoldRecording: Bool { hybridKind == .autoHold && state == .recording }

    func requestFinish() {
        guard state == .recording else { return }
        stopRecordingAndTranscribe()
    }

    /// Keep the last utterance, persist it for recovery, and put it on the
    /// clipboard so Cmd+V works when there was no text field to type into.
    private func commitTranscript(_ text: String) {
        lastTranscription = text
        transcriptionError = nil
        AppSettings.shared.recordTranscript(text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var whisperBridge: WhisperBridge?
    private let audioCapture = AudioCapture()
    private let textInjector = TextInjector()
    private let soundFeedback = SoundFeedback()
    private var hotkeyMonitor: HotkeyMonitor?

    private let minRecordingDuration: TimeInterval = 0.3
    private var recordingStartTime: Date?
    private var holdAppearedAt: Date?
    private var startClickPlayed = false
    private var goLiveWorkItem: DispatchWorkItem?
    private var isArmingCapture = false
    private var captureGeneration = 0
    private var hybridPressedAt: Date?
    private var pendingStopAfterArm = false
    private var skipNextStopSound = false

    private var accessibilityPoller: Timer?

    /// Pending toggle-mode hold timer. Cancelled if the user releases the key
    /// before the threshold; cleared after firing.
    private var holdWorkItem: DispatchWorkItem?

    /// Hybrid mode: hold = push-to-talk, double-tap or hold+Space = auto-hold.
    private var hybridKind: HybridRecordingKind = .none
    private var hybridHotkeyDown = false
    private var hybridAwaitingSecondTap = false
    private var hybridHoldWorkItem: DispatchWorkItem?
    private var hybridTapWorkItem: DispatchWorkItem?
    private var hybridFinishPressArmed = false

    /// After an instant start, a release shorter than this is discarded rather
    /// than transcribed. Fn+Space still latches auto-hold.
    static let hybridHoldThreshold: TimeInterval = 0.18
    static let hybridDoubleTapWindow: TimeInterval = 0.40
    static let holdDisplayMinimum: TimeInterval = 0.15

    enum HybridRecordingKind: Equatable { case none, pushToTalk, autoHold }

    init() {
        let axTrusted = AXIsProcessTrusted()
        fputs("[DictationEngine] Init. Accessibility: \(axTrusted)\n", stderr)
        audioCapture.onConfigurationChange = { [weak self] in
            self?.handleInputConfigurationChange()
        }
        audioCapture.onMaxDurationReached = { [weak self] in
            self?.handleMaxRecordingDurationReached()
        }
        audioCapture.onBarLevels = { [weak self] levels in
            DispatchQueue.main.async {
                guard let self, self.state == .recording, !self.isHoldingForToggle else { return }
                var next = self.inputLevels
                if next.count != AudioCapture.visualizerBars {
                    next = Array(repeating: 0, count: AudioCapture.visualizerBars)
                }
                for i in 0..<AudioCapture.visualizerBars {
                    let incoming = i < levels.count ? levels[i] : 0
                    if incoming > next[i] {
                        next[i] = incoming
                    } else {
                        next[i] = next[i] * 0.48 + incoming * 0.52
                    }
                }
                self.inputLevels = next
            }
        }
        setupHotkeyMonitor()
        hotkeyMonitor?.start()
        loadModelAsync()
        LaunchAtLoginHelper.reconcile()

        // Free whisper's Metal-backed contexts before exit(): NSApplication's
        // terminate path never runs Swift deinits, and ggml aborts at exit
        // (GGML_ASSERT in ggml_metal_rsets_free) if Metal resources are still
        // alive when its static device registry is destroyed. Posted on the
        // main thread; the engine lives for the whole process, so the observer
        // is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForTermination()
        }

        if !axTrusted {
            PermissionManager.shared.promptAccessibilityIfNeeded()
        }
        startAccessibilityPoller()
    }

    private func startAccessibilityPoller() {
        accessibilityPoller?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            PermissionManager.shared.checkPermissions()
            guard let self else { return }
            if AXIsProcessTrusted() {
                if self.hotkeyMonitor?.isRunning != true {
                    fputs("[DictationEngine] Accessibility granted. Starting hotkey monitor.\n", stderr)
                    self.restartHotkeyMonitor()
                }
            } else if self.hotkeyMonitor?.isRunning == true {
                fputs("[DictationEngine] Accessibility lost. Stopping hotkey monitor.\n", stderr)
                self.hotkeyMonitor?.stop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoller = timer
    }

    func restartHotkeyMonitor() {
        cancelPendingToggle()
        hotkeyMonitor?.stop()
        setupHotkeyMonitor()
        hotkeyMonitor?.start()
    }

    // MARK: - Model Loading

    private func loadModelAsync() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let modelPath = ModelManager.shared.activeModelPath()
                guard let modelPath else {
                    await MainActor.run {
                        self.modelLoadError = "No model found. Open Settings to download a model."
                    }
                    return
                }
                let bridge = try WhisperBridge(modelPath: modelPath)

                // Pre-warm GPU: JIT-compile Metal shaders with a tiny dummy inference.
                // Async so this cooperative-pool task isn't blocked during warmup.
                await bridge.warmup()

                await MainActor.run {
                    self.whisperBridge = bridge
                    self.isModelLoaded = true
                    self.modelLoadError = nil
                }
            } catch {
                await MainActor.run {
                    self.modelLoadError = "Failed to load model: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Set when `reloadModel()` is requested while a transcription is in flight.
    /// Consumed on the return to idle. Main-actor only.
    private var pendingModelReload = false

    /// Swap the active model. If a transcription is mid-flight (`.recording` captured
    /// no bridge yet, but `.processing`/`.typing` hold the current bridge locally and
    /// must finish on it), nulling `whisperBridge` here would strand that task or drop
    /// the utterance. So only reload immediately when idle; otherwise defer until the
    /// engine returns to idle (the new selection is already persisted in AppSettings,
    /// so the deferred reload picks it up). Called on the main actor.
    func reloadModel() {
        guard state == .idle else {
            pendingModelReload = true
            return
        }
        performModelReload()
    }

    private func performModelReload() {
        pendingModelReload = false
        isModelLoaded = false
        modelLoadError = nil
        whisperBridge = nil
        loadModelAsync()
    }

    /// Transition to idle and, if a model reload was deferred while the engine was
    /// busy, perform it now. Main-actor only.
    private func returnToIdle() {
        state = .idle
        inputLevels = Array(repeating: 0, count: AudioCapture.visualizerBars)
        isHoldingForToggle = false
        isArmingCapture = false
        holdAppearedAt = nil
        startClickPlayed = false
        pendingStopAfterArm = false
        skipNextStopSound = false
        hybridPressedAt = nil
        goLiveWorkItem?.cancel()
        goLiveWorkItem = nil
        IslandController.shared.setVisible(false)
        drainCancelFlag = nil
        hybridKind = .none
        if pendingModelReload { performModelReload() }
    }

    // MARK: - Hotkey

    private func setupHotkeyMonitor() {
        hotkeyMonitor = HotkeyMonitor(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() },
            onLatchKeyDown: { [weak self] in self?.handleLatchKeyDown() },
            onCancelKeyDown: { [weak self] in self?.handleCancelKeyDown() ?? false }
        )
    }

    func startMonitoring() {
        hotkeyMonitor?.start()
    }

    func stopMonitoring() {
        cancelPendingToggle()
        hotkeyMonitor?.stop()
    }

    // MARK: - Hotkey Mode Dispatch

    /// What a key-DOWN should do, given the hotkey mode and current state.
    /// Pure/static so the mode dispatch is unit-testable without hardware.
    ///
    /// Cancel semantics follow each mode's existing intent model:
    /// - Push-to-talk: any key-down is deliberate, so a key-down while transcribing
    ///   cancels the in-flight inference immediately. This handler is only invoked
    ///   for genuine key-down / modifier-press events — the HotkeyMonitor watchdog
    ///   only ever synthesizes key-UP — so a cancel can never come from watchdog
    ///   recovery.
    /// - Toggle: every action requires the deliberate ~1.5s hold, and a quick tap is
    ///   ignored. An instant cancel here would let a stray tap destroy a transcription
    ///   (worst case: the 5-min cap or a device change auto-stopped a long recording,
    ///   the user taps to "stop", and the tap lands during .processing). So toggle
    ///   always goes through `scheduleToggleAction`; the cancel happens only if the
    ///   full hold completes while transcribing (see `toggleHoldAction`).
    enum KeyDownAction: Equatable { case startRecording, scheduleToggle, cancelTranscription, handleHybrid }

    static func keyDownAction(mode: AppSettings.HotkeyMode, state: DictationState) -> KeyDownAction {
        switch mode {
        case .pushToTalk:
            return (state == .processing || state == .typing) ? .cancelTranscription : .startRecording
        case .toggle:
            return .scheduleToggle
        case .hybrid:
            return .handleHybrid
        }
    }

    /// What the toggle hold work item should do when it fires after the full hold
    /// duration. Pure/static for unit testing. A completed hold during
    /// .processing/.typing is as deliberate as one during .recording — it cancels
    /// the in-flight transcription (silently; already-typed segments remain).
    enum ToggleHoldAction: Equatable { case startRecording, stopAndTranscribe, cancelTranscription }

    static func toggleHoldAction(state: DictationState) -> ToggleHoldAction {
        switch state {
        case .idle: return .startRecording
        case .recording: return .stopAndTranscribe
        case .processing, .typing: return .cancelTranscription
        }
    }

    private func handleKeyDown() {
        switch Self.keyDownAction(mode: AppSettings.shared.hotkeyMode, state: state) {
        case .cancelTranscription:
            cancelTranscription()
        case .startRecording:
            startRecording()
        case .scheduleToggle:
            scheduleToggleAction()
        case .handleHybrid:
            handleHybridKeyDown()
        }
    }

    /// Ask the active bridge to abort the running decode. The `transcribe` call then
    /// throws `WhisperError.cancelled`, which the transcription task treats as a silent
    /// reset to idle (no error surfaced). Already-typed segments remain.
    ///
    /// A live session draining after stop cancels differently: it flips its own shared
    /// session flag, which every queued chunk decode polls. `bridge.cancelTranscription()`
    /// would be wrong there — its single-flight `activeCancelFlag` is overwritten as each
    /// queued call enters and cleared as each finishes, so it can target the wrong decode
    /// (or none at all).
    private func cancelTranscription() {
        fputs("[DictationEngine] Cancel requested during \(state.rawValue).\n", stderr)
        if let liveFlagForDrain = drainCancelFlag {
            liveFlagForDrain.cancel()
        } else {
            whisperBridge?.cancelTranscription()
        }
    }

    private func handleKeyUp() {
        switch AppSettings.shared.hotkeyMode {
        case .pushToTalk:
            stopRecordingAndTranscribe()
        case .toggle:
            cancelPendingToggle()
        case .hybrid:
            handleHybridKeyUp()
        }
    }

    private func handleLatchKeyDown() {
        guard AppSettings.shared.hotkeyMode == .hybrid else { return }
        handleHybridLatch()
    }

    enum HybridKeyDownAction: Equatable {
        case startPushToTalk, startAutoHold, armFinishPress, cancelTranscription, none
    }

    static func hybridKeyDownAction(
        state: DictationState,
        kind: HybridRecordingKind,
        awaitingSecondTap: Bool
    ) -> HybridKeyDownAction {
        if awaitingSecondTap {
            switch state {
            case .idle: return .startAutoHold
            case .recording: return kind == .autoHold ? .armFinishPress : .none
            case .processing, .typing: return .startPushToTalk
            }
        }
        switch state {
        case .idle: return .startPushToTalk
        case .processing, .typing: return .startPushToTalk
        case .recording: return kind == .autoHold ? .armFinishPress : .none
        }
    }

    enum HybridKeyUpAction: Equatable { case stopPushToTalk, finishAutoHold, discardAsTap, markTap, none }

    static func hybridKeyUpAction(
        state: DictationState,
        kind: HybridRecordingKind,
        holdTimerWasPending: Bool,
        finishPressArmed: Bool,
        heldLongEnough: Bool
    ) -> HybridKeyUpAction {
        if kind == .pushToTalk {
            return heldLongEnough ? .stopPushToTalk : .discardAsTap
        }
        if kind == .autoHold && state == .recording && finishPressArmed { return .finishAutoHold }
        if holdTimerWasPending { return .markTap }
        return .none
    }

    enum HybridLatchAction: Equatable {
        case startAutoHold, convertToAutoHold, none
    }

    static func hybridLatchAction(
        state: DictationState,
        kind: HybridRecordingKind
    ) -> HybridLatchAction {
        switch state {
        case .idle: return .startAutoHold
        case .recording: return kind == .autoHold ? .none : .convertToAutoHold
        case .processing, .typing: return .none
        }
    }

    static func hybridCancelAction(state: DictationState) -> Bool {
        state != .idle
    }

    private func handleHybridKeyDown() {
        hybridHotkeyDown = true
        hybridPressedAt = Date()
        pendingStopAfterArm = false
        switch Self.hybridKeyDownAction(state: state, kind: hybridKind, awaitingSecondTap: hybridAwaitingSecondTap) {
        case .startPushToTalk:
            hybridAwaitingSecondTap = false
            hybridFinishPressArmed = false
            cancelHybridTapWindow()
            cancelHybridHoldTimer()
            startHybridRecording(.pushToTalk)
        case .startAutoHold:
            cancelHybridHoldTimer()
            hybridAwaitingSecondTap = false
            hybridFinishPressArmed = false
            startHybridRecording(.autoHold)
        case .armFinishPress:
            cancelHybridHoldTimer()
            hybridAwaitingSecondTap = false
            hybridFinishPressArmed = true
        case .cancelTranscription:
            cancelHybridHoldTimer()
            hybridAwaitingSecondTap = false
            hybridFinishPressArmed = false
            cancelSession()
        case .none:
            break
        }
    }

    private func handleHybridKeyUp() {
        hybridHotkeyDown = false
        let holdWasPending = hybridHoldWorkItem != nil
        let finishArmed = hybridFinishPressArmed
        hybridFinishPressArmed = false
        cancelHybridHoldTimer()
        let heldLongEnough: Bool = {
            guard let start = hybridPressedAt else { return false }
            return Date().timeIntervalSince(start) >= Self.hybridHoldThreshold
        }()
        switch Self.hybridKeyUpAction(
            state: state,
            kind: hybridKind,
            holdTimerWasPending: holdWasPending,
            finishPressArmed: finishArmed,
            heldLongEnough: heldLongEnough
        ) {
        case .stopPushToTalk, .finishAutoHold:
            if state == .recording {
                stopRecordingAndTranscribe()
            } else {
                pendingStopAfterArm = true
                skipNextStopSound = true
                soundFeedback.playStopSound()
            }
        case .discardAsTap:
            discardRecordingForTap()
        case .markTap:
            hybridAwaitingSecondTap = true
            scheduleHybridTapWindow()
        case .none:
            break
        }
    }

    private func handleHybridLatch() {
        guard hybridHotkeyDown else { return }
        switch Self.hybridLatchAction(state: state, kind: hybridKind) {
        case .startAutoHold:
            cancelHybridHoldTimer()
            hybridAwaitingSecondTap = false
            hybridFinishPressArmed = false
            if isArmingCapture || state == .recording {
                hybridKind = .autoHold
            } else {
                startHybridRecording(.autoHold)
            }
        case .convertToAutoHold:
            hybridKind = .autoHold
            hybridFinishPressArmed = false
        case .none:
            break
        }
    }

    @discardableResult
    private func handleCancelKeyDown() -> Bool {
        guard Self.hybridCancelAction(state: state) || isArmingCapture else { return false }
        cancelSession()
        return true
    }

    /// Drop the current recording or in-flight transcription without typing more text.
    private func cancelSession() {
        cancelHybridHoldTimer()
        cancelHybridTapWindow()
        hybridAwaitingSecondTap = false
        hybridFinishPressArmed = false
        hybridHotkeyDown = false
        guard isArmingCapture || state != .idle else { return }
        fputs("[DictationEngine] Session cancelled during \(state.rawValue).\n", stderr)
        soundFeedback.playStopSound()
        abortCapture()
        returnToIdle()
    }

    /// Drop in-flight capture or transcription without hiding the island.
    /// Bumps `captureGeneration` so delayed go-live / finish work is a no-op.
    private func abortCapture() {
        captureGeneration += 1
        goLiveWorkItem?.cancel()
        goLiveWorkItem = nil
        pendingStopAfterArm = false
        stopCaptureHardware()
        isArmingCapture = false
        recordingStartTime = nil
    }

    private func stopCaptureHardware() {
        audioCapture.onSamples = nil
        if audioCapture.isRecording { _ = audioCapture.stopRecording() }
        liveSessionFlag?.cancel()
        teardownLiveSession()
        whisperBridge?.cancelTranscription()
        drainCancelFlag?.cancel()
        drainCancelFlag = nil
    }

    private func startHybridRecording(_ kind: HybridRecordingKind) {
        hybridKind = kind
        startRecording()
    }

    /// Instant Hold island plus the press click, before any audio work.
    private func showIslandImmediately() {
        isHoldingForToggle = true
        holdAppearedAt = Date()
        IslandController.shared.revealHold()
        if !startClickPlayed {
            startClickPlayed = true
            soundFeedback.playStartSound()
        }
        IslandController.shared.flushPresentation()
    }

    private func finishHoldAndGoLive() {
        guard state == .recording else { return }
        isHoldingForToggle = false
        IslandController.shared.revealLive()
    }

    /// First half of a double-tap: drop the instant-start capture without
    /// transcribing. A new press is a fresh PTT, not a latch.
    private func discardRecordingForTap() {
        soundFeedback.playStopSound()
        abortCapture()
        returnToIdle()
    }

    private func scheduleHybridTapWindow() {
        cancelHybridTapWindow()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hybridTapWorkItem = nil
            self.hybridAwaitingSecondTap = false
        }
        hybridTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hybridDoubleTapWindow, execute: work)
    }

    private func cancelHybridHoldTimer() {
        hybridHoldWorkItem?.cancel()
        hybridHoldWorkItem = nil
    }

    private func cancelHybridTapWindow() {
        hybridTapWorkItem?.cancel()
        hybridTapWorkItem = nil
    }

    /// Toggle mode: schedule a deferred start/stop after `toggleHoldDuration` seconds.
    /// If the user releases the key first, `cancelPendingToggle()` aborts the work item.
    private func scheduleToggleAction() {
        cancelPendingToggle()
        isHoldingForToggle = true
        IslandController.shared.revealHold()
        // Capture the duration ONCE at schedule time. We pass this same value to the
        // trim path so the audio trimmed at stop matches what was actually waited out,
        // even if the slider value changes between schedule and stop.
        let duration = AppSettings.shared.toggleHoldDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isHoldingForToggle = false
            self.holdWorkItem = nil
            // Defensive: settings may have changed mid-hold.
            guard AppSettings.shared.hotkeyMode == .toggle else { return }
            switch Self.toggleHoldAction(state: self.state) {
            case .startRecording:
                self.startRecording()
            case .stopAndTranscribe:
                self.stopRecordingAndTranscribe(trimTrailingSeconds: duration)
            case .cancelTranscription:
                self.cancelTranscription()
            }
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelPendingToggle() {
        let wasHolding = isHoldingForToggle
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if isHoldingForToggle { isHoldingForToggle = false }
        cancelHybridHoldTimer()
        cancelHybridTapWindow()
        hybridHotkeyDown = false
        hybridAwaitingSecondTap = false
        hybridFinishPressArmed = false
        if wasHolding, state == .idle {
            IslandController.shared.setVisible(false)
        }
    }

    // MARK: - Prompt Assembly

    /// Whisper's initial_prompt is capped at ~1024 tokens (~750 words). Exceeding it
    /// triggers `whisper_tokenize: too many resulting tokens` and degrades accuracy
    /// (see CLAUDE.md). We budget 700 words as a safe margin.
    static let promptWordBudget = 700

    /// Builds the whisper initial_prompt from the base vocabulary prompt plus the
    /// user's custom terms, staying within `promptWordBudget` words. The base prompt
    /// is truncated first if it alone exceeds the budget; custom terms then fill any
    /// remaining word budget. Pure/static so it is unit-testable without the engine.
    ///
    /// - Parameter transcriptTail: text already committed in this dictation, used by
    ///   live mode so each chunk decodes with the preceding words as context. Empty
    ///   (the default) leaves the prompt byte-identical to the non-live build.
    static func buildPrompt(base: String, customTerms: [String], transcriptTail: String = "") -> String {
        let baseWords = base.split(separator: " ")
        let cappedBase = baseWords.count > promptWordBudget
            ? baseWords.prefix(promptWordBudget).joined(separator: " ")
            : base

        let termBudget = max(0, promptWordBudget - baseWords.count)
        let termsToAdd = Array(customTerms.prefix(termBudget))
        let withTerms = termsToAdd.isEmpty
            ? cappedBase
            : cappedBase + ", " + termsToAdd.joined(separator: ", ")

        // Committed-transcript tail: budgeted by ACTUAL word count (terms above
        // deliberately keep their historical one-unit-each accounting), capped
        // at 50 words, appended last — closest to the decode.
        let tailWords = transcriptTail.split(separator: " ")
        let usedWords = min(baseWords.count, promptWordBudget) + termsToAdd.count
        let tailBudget = min(50, max(0, promptWordBudget - usedWords))
        guard tailBudget > 0, !tailWords.isEmpty else { return withTerms }
        return withTerms + " " + tailWords.suffix(tailBudget).joined(separator: " ")
    }

    // MARK: - Recording Flow

    private func startRecording() {
        guard isModelLoaded else { return }
        showIslandImmediately()

        captureGeneration += 1
        goLiveWorkItem?.cancel()
        goLiveWorkItem = nil
        transcriptionError = nil
        inputLevels = Array(repeating: 0, count: AudioCapture.visualizerBars)
        isArmingCapture = true
        recordingStartTime = nil
        let generation = captureGeneration

        DispatchQueue.main.async { [weak self] in
            self?.armCapture(generation: generation)
        }
    }

    private func armCapture(generation: Int) {
        guard generation == captureGeneration, isArmingCapture else { return }
        stopCaptureHardware()

        do {
            try audioCapture.startRecording()
        } catch {
            fputs("[DictationEngine] Failed to start recording: \(error)\n", stderr)
            teardownLiveSession()
            hybridKind = .none
            if generation == captureGeneration { returnToIdle() }
            return
        }
        guard generation == captureGeneration, isArmingCapture else {
            if audioCapture.isRecording { _ = audioCapture.stopRecording() }
            return
        }
        isArmingCapture = false
        state = .recording
        recordingStartTime = Date()
        let live = startLiveSessionIfEnabled()
        fputs("[DictationEngine] Recording (live: \(live))\n", stderr)

        if pendingStopAfterArm {
            pendingStopAfterArm = false
            stopRecordingAndTranscribe()
            return
        }

        let shown = holdAppearedAt ?? Date()
        let remaining = Self.holdDisplayMinimum - Date().timeIntervalSince(shown)
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.captureGeneration else { return }
            self.goLiveWorkItem = nil
            self.finishHoldAndGoLive()
        }
        goLiveWorkItem = work
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        } else {
            work.perform()
        }
    }

    /// - Parameter trimTrailingSeconds: number of seconds to trim from the end of the audio
    ///   buffer before transcription. Used by toggle mode to discard the silent hold-to-stop
    ///   interval (otherwise Whisper hallucinates trailing punctuation/filler from the silence).
    ///   Push-to-talk passes 0.
    private func stopRecordingAndTranscribe(trimTrailingSeconds: TimeInterval = 0) {
        guard state == .recording else { return }
        goLiveWorkItem?.cancel()
        goLiveWorkItem = nil
        isHoldingForToggle = false
        IslandController.shared.revealLive()
        if skipNextStopSound {
            skipNextStopSound = false
        } else {
            soundFeedback.playStopSound()
        }
        let generation = captureGeneration
        if isLiveSession {
            stopLiveSession(trimTrailingSeconds: trimTrailingSeconds)
            return
        }

        let audioBuffer = audioCapture.stopRecording(trimTrailingSeconds: trimTrailingSeconds)

        // Check minimum duration
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) < minRecordingDuration {
            returnToIdle()
            return
        }

        guard !audioBuffer.isEmpty else {
            returnToIdle()
            return
        }

        state = .processing

        let bridge = self.whisperBridge
        let prompt = Self.buildPrompt(
            base: AppSettings.shared.vocabularyPrompt,
            customTerms: AppSettings.shared.customTerms
        )
        let injector = self.textInjector
        let feedback = self.soundFeedback

        Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for all enqueued typing to drain, then surface the result and go idle.
            // injector.flush() blocks this cooperative-pool thread — but it is only a
            // wait (typing itself runs on the injector's own queue), which is the same
            // accepted tradeoff the old synchronous transcribe made.
            func finish(transcript: String?, error: String?) async {
                injector.flush()
                await MainActor.run { [weak self] in
                    guard let self, self.captureGeneration == generation else { return }
                    if let transcript, !transcript.isEmpty {
                        self.commitTranscript(transcript)
                    }
                    if let error { self.transcriptionError = error }
                    feedback.playDoneSound()
                    self.returnToIdle()
                }
            }

            guard let bridge else {
                await finish(transcript: nil, error: nil)
                return
            }

            await MainActor.run { [weak self] in
                guard let self, self.captureGeneration == generation else { return }
                self.state = .typing
            }

            // Stream: correct and type each segment as it's decoded. Segments are
            // enqueued to the injector (non-blocking) and accumulated for the final
            // lastTranscription. The collector is written only from the whisper queue
            // (segment callbacks are serial) and read after `await` returns, which
            // happens-after all writes — so @unchecked Sendable is sound.
            let collected = TranscriptCollector()
            do {
                _ = try await bridge.transcribe(audioBuffer: audioBuffer, prompt: prompt) { segment in
                    let corrected = TextCorrector.shared.correct(segment)
                    // Never log transcribed content — it's the user's private dictation.
                    injector.type(text: collected.joinAndAppend(corrected))
                }
            } catch let error as WhisperError where error.isCancellation {
                fputs("[DictationEngine] Transcription cancelled by user.\n", stderr)
                await finish(transcript: collected.text.isEmpty ? nil : collected.text, error: nil)
                return
            } catch {
                fputs("[DictationEngine] Transcription failed: \(error)\n", stderr)
                await finish(transcript: collected.text.isEmpty ? nil : collected.text, error: error.localizedDescription)
                return
            }

            await finish(transcript: collected.text, error: nil)
        }
    }

    // MARK: - Live Dictation Session

    private enum LiveWorkItem {
        case chunk([Float])
        case residual([Float])
    }

    /// Residual minimum is SAMPLE COUNT (≈0.3 s @16 kHz) — the wall-clock
    /// minRecordingDuration check measures the whole session and would always
    /// pass after a live session. Distinct from VADChunkGate.minSpeechWindows,
    /// which gates chunks by accumulated speech, not raw length.
    static let residualMinSeconds = 0.3
    static func residualMeetsMinimum(sampleCount: Int) -> Bool {
        Double(sampleCount) >= 16000 * residualMinSeconds
    }

    /// Stop-time termination (append-only): a session whose committed text
    /// never ended a sentence gets exactly one period at stop. Chunks are
    /// never auto-terminated (a "final chunk" is unknowable at commit time —
    /// toggle mode's hold-to-stop guarantees the last utterance commits as an
    /// intermediate chunk).
    static func needsTerminalPeriod(committed: String) -> Bool {
        guard let last = committed.last else { return false }
        return !".!?".contains(last)
    }

    private var liveSegmenter: VADSegmenter?
    private var liveContinuation: AsyncStream<LiveWorkItem>.Continuation?
    private var liveSessionFlag: CancellationFlag?

    /// The session flag kept alive for the drain phase (stop → consumer finish),
    /// after the main-actor session references are cleared. This is what a cancel
    /// during .processing/.typing flips. Cleared in `returnToIdle()`.
    private var drainCancelFlag: CancellationFlag?

    private var isLiveSession: Bool { liveSegmenter != nil }

    /// Engine-side guard (evaluated per session): the setting stores intent;
    /// live runs only when the VAD model is actually on disk, resolved fresh
    /// (WhisperBridge's cached copy from its own init must not be reused).
    private func startLiveSessionIfEnabled() -> Bool {
        guard AppSettings.shared.liveDictationEnabled,
              let vadPath = ModelManager.shared.vadModelPath(),
              let bridge = whisperBridge else { return false }
        do {
            let segmenter = try VADSegmenter(vadModelPath: vadPath)
            let sessionFlag = CancellationFlag()
            let (stream, continuation) = AsyncStream.makeStream(of: LiveWorkItem.self)

            liveSegmenter = segmenter
            liveContinuation = continuation
            liveSessionFlag = sessionFlag

            // Invoked synchronously on the segmenter's queue, so it must touch
            // NO main-actor state: the continuation is captured by value, never
            // read back through `self.liveContinuation`. `yield` is thread-safe
            // and non-blocking, and the stop path's `finishAndCollectResidual()`
            // barrier happens-after every commit's yield — so every committed
            // chunk is in the stream before the residual and `finish()`, and none
            // can be orphaned by the stop path clearing `liveContinuation`.
            segmenter.onChunk = { chunk in continuation.yield(.chunk(chunk)) }
            audioCapture.onSamples = { samples in segmenter.append(samples) }
            segmenter.start()
            runLiveConsumer(stream: stream, bridge: bridge, sessionFlag: sessionFlag)
            return true
        } catch {
            fputs("[DictationEngine] VAD init failed — falling back to non-live: \(error)\n", stderr)
            return false
        }
    }

    /// ONE sequential consumer: strict output order and a natural drain point
    /// fall out of the single loop (per-chunk Tasks would guarantee neither).
    /// Owns the whole post-stream finish: terminal period, flush, done sound,
    /// lastTranscription, returnToIdle — unconditionally, even when the
    /// residual was empty (the common case; the non-live empty shortcut must
    /// never be taken here or queued typing gets stranded).
    private func runLiveConsumer(
        stream: AsyncStream<LiveWorkItem>,
        bridge: WhisperBridge,
        sessionFlag: CancellationFlag
    ) {
        let injector = self.textInjector
        let feedback = self.soundFeedback
        let collected = TranscriptCollector()
        let generation = captureGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            var surfacedError: String?

            for await item in stream {
                if sessionFlag.isCancelled && surfacedError == nil {
                    continue   // user cancel during drain: skip remaining work silently
                }
                let (samples, isResidual): ([Float], Bool)
                switch item {
                case .chunk(let s): (samples, isResidual) = (s, false)
                case .residual(let s): (samples, isResidual) = (s, true)
                }
                guard surfacedError == nil else { continue }  // failure: drain and discard

                let prompt = Self.buildPrompt(
                    base: AppSettings.shared.vocabularyPrompt,
                    customTerms: AppSettings.shared.customTerms,
                    transcriptTail: collected.text
                )
                do {
                    _ = try await bridge.transcribe(
                        audioBuffer: samples,
                        prompt: prompt,
                        cancelFlag: sessionFlag,
                        vad: isResidual   // chunks are pre-trimmed; residual is raw
                    ) { segment in
                        let context = CorrectionContext(
                            atSentenceStart: collected.atSentenceStart,
                            appendPeriod: false   // termination is the stop-time rule
                        )
                        let corrected = TextCorrector.shared.correct(segment, context: context)
                        guard !corrected.isEmpty else { return }
                        injector.type(text: collected.joinAndAppend(corrected))
                    }
                } catch let error as WhisperError where error.isCancellation {
                    continue   // silent: user cancel, or cascade after a failure
                } catch {
                    fputs("[DictationEngine] Live decode failed: \(error)\n", stderr)
                    surfacedError = error.localizedDescription
                    sessionFlag.cancel()   // abort the queue; cascade drains silently above
                }
            }

            // Stream closed: stop-time finish (unconditional drain + flush).
            if surfacedError == nil, Self.needsTerminalPeriod(committed: collected.text) {
                injector.type(text: ".")
            }
            injector.flush()

            let finalError = surfacedError
            await MainActor.run { [weak self] in
                guard let self, self.captureGeneration == generation else { return }
                if !collected.text.isEmpty {
                    var transcript = collected.text
                    if Self.needsTerminalPeriod(committed: transcript) { transcript += "." }
                    self.commitTranscript(transcript)
                }
                if let finalError { self.transcriptionError = finalError }
                feedback.playDoneSound()
                self.returnToIdle()
            }
        }
    }

    /// Live stop: discard the full capture buffer (its speech was already
    /// committed chunk-by-chunk), collect the segmenter's residual, and close
    /// the stream — the consumer owns everything after this point, including
    /// returnToIdle. State moves to .processing/.typing to cover the drain.
    private func stopLiveSession(trimTrailingSeconds: TimeInterval) {
        audioCapture.onSamples = nil
        _ = audioCapture.stopRecording()   // tap removed; buffer intentionally discarded
        recordingStartTime = nil

        var residual = liveSegmenter?.finishAndCollectResidual() ?? []
        if trimTrailingSeconds > 0 {
            let toTrim = Int(trimTrailingSeconds * 16000)
            residual = residual.count > toTrim ? Array(residual.dropLast(toTrim)) : []
        }

        state = .processing
        if Self.residualMeetsMinimum(sampleCount: residual.count) {
            state = .typing
            liveContinuation?.yield(.residual(residual))
        }
        liveContinuation?.finish()   // consumer drains, flushes, returns to idle
        drainCancelFlag = liveSessionFlag
        clearLiveSessionReferences()
    }

    /// Drop main-actor references to the session. The consumer task holds its
    /// own copies (stream, flag, collector) and finishes independently.
    private func clearLiveSessionReferences() {
        liveSegmenter = nil
        liveContinuation = nil
        liveSessionFlag = nil
    }

    /// App is terminating (main thread; exit() follows, skipping all deinits).
    /// Stop capture, tear down any live session, and free the whisper context
    /// explicitly via `shutdownAndFree()` — ggml's at-exit Metal assert fires if
    /// it is still alive, and refcounted deinit cannot be relied on here: a
    /// live-session consumer task holds its own bridge reference and finishes
    /// on the main actor, which is blocked in this very handler. The segmenter's
    /// VAD context is CPU-only (not implicated in the Metal assert); its release
    /// through teardown stays best-effort.
    private func prepareForTermination() {
        fputs("[DictationEngine] Terminating — freeing whisper context\n", stderr)
        audioCapture.onSamples = nil
        if audioCapture.isRecording { _ = audioCapture.stopRecording() }
        // Cancel BEFORE the teardown drain so chunks committed during the drain
        // abort instead of starting fresh decodes (same rule as teardownLiveSession).
        liveSessionFlag?.cancel()
        teardownLiveSession()
        whisperBridge?.shutdownAndFree()
        whisperBridge = nil
        fputs("[DictationEngine] Whisper context freed\n", stderr)
    }

    /// Full teardown for paths where the consumer must ALSO stop (start
    /// failure, config change): close the stream so the consumer's finish
    /// block runs, then clear references.
    private func teardownLiveSession() {
        audioCapture.onSamples = nil
        _ = liveSegmenter?.finishAndCollectResidual()   // discard residual
        liveContinuation?.finish()
        // Same hand-off as stopLiveSession: a cancel arriving during this drain
        // must flip the session flag deterministically. Without it the cancel
        // falls through to the bridge's single-flight flag, which only happens
        // to work while a chunk decode is in flight. Cleared in returnToIdle().
        drainCancelFlag = liveSessionFlag
        clearLiveSessionReferences()
    }

    /// Invoked (on the audio tap thread) when a recording reaches the maximum
    /// duration cap. Route it through the normal stop-and-transcribe path on the main
    /// actor so what was captured is still transcribed, and surface a brief,
    /// non-error explanation. `stopRecordingAndTranscribe()` leaves any transcript we
    /// produce intact (it clears the status on success once text is typed).
    private func handleMaxRecordingDurationReached() {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            fputs("[DictationEngine] Max recording duration reached — transcribing what was captured.\n", stderr)
            self.stopRecordingAndTranscribe()
            // Set after stop so it isn't cleared by startRecording's reset; visible
            // during processing until the successful transcript clears it.
            self.transcriptionError = "Reached the \(Int(AudioCapture.maxRecordingSeconds / 60))-minute recording limit. Transcribing what was captured."
        }
    }

    /// Invoked (on an arbitrary thread) when the audio engine's configuration
    /// changes mid-recording — a device being unplugged, a newly plugged-in device
    /// becoming default, or a sample-rate change. All invalidate the running tap,
    /// so stop cleanly and surface the reason. No auto-restart in this phase.
    private func handleInputConfigurationChange() {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            if self.isLiveSession {
                fputs("[DictationEngine] Audio input changed during live session — stopping.\n", stderr)
                self.audioCapture.onSamples = nil
                _ = self.audioCapture.stopRecording()
                self.soundFeedback.playStopSound()
                self.recordingStartTime = nil
                self.state = .processing        // consumer's finish returns to idle
                self.teardownLiveSession()      // residual discarded; committed text remains
                self.transcriptionError = "Audio input changed. Recording stopped."
                return
            }
            fputs("[DictationEngine] Audio input configuration changed during recording — stopping.\n", stderr)
            _ = self.audioCapture.stopRecording()
            self.soundFeedback.playStopSound()
            self.recordingStartTime = nil
            self.returnToIdle()
            self.transcriptionError = "Audio input changed. Recording stopped."
        }
    }
}

/// Accumulates corrected transcript segments during a streaming transcription.
/// Appended to only from the whisper decode queue (segment callbacks are delivered
/// serially) and read once after the transcribe `await` returns, which happens-after
/// all appends. That ordering makes the unsynchronized access sound; hence
/// `@unchecked Sendable`.
///
/// The live consumer extends that ordering rather than breaking it: one collector is
/// shared across a session's sequential decodes, and its reads (`text` for the next
/// chunk's prompt tail and the finish block; `atSentenceStart` inside a later decode's
/// segment callback) are still never concurrent with a write. Each `await transcribe`
/// in the single consumer loop is a happens-after edge over that decode's whisper-queue
/// writes, and the next decode — the only other writer — starts only after that await
/// returns. So at any instant exactly one thread touches `text`.
final class TranscriptCollector: @unchecked Sendable {
    private(set) var text: String = ""

    /// True when the next appended segment begins a sentence: nothing has
    /// been collected yet, or the collected text ends in terminal punctuation.
    var atSentenceStart: Bool {
        guard let last = text.last else { return true }
        return ".!?".contains(last)
    }

    /// Returns `segment` as it should be typed — with a leading space when
    /// joining onto already-collected text — and appends that same piece to
    /// `text`, so the typed stream and the collected transcript cannot drift.
    /// The separator is applied AFTER correction: the corrector trims leading
    /// whitespace, so a pre-correction separator would be eaten.
    func joinAndAppend(_ segment: String) -> String {
        let piece = text.isEmpty ? segment : " " + segment
        text += piece
        return piece
    }
}
