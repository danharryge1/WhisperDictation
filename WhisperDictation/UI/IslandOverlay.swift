import AppKit
import QuartzCore
import SwiftUI

/// Compact floating pill, bottom-centre, sized like Wispr Flow's recording bar.
final class IslandController {
    static let shared = IslandController()
    static let holdSize = NSSize(width: 78, height: 26)

    private var panel: NSPanel?
    private var root: NSView?
    private var hosting: NSHostingView<IslandContent>?
    private var holdPill: NSView?
    private var showingHold = false
    private var engine: DictationEngine?
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var appActivateObserver: NSObjectProtocol?

    private init() {}

    func attach(engine: DictationEngine) {
        self.engine = engine
        if panel == nil { makePanel(engine: engine) }
        listenForScreenChanges()
        listenForActiveScreen()
        reposition()
        if ProcessInfo.processInfo.environment["WD_PREVIEW_ISLAND"] == "1" {
            revealLive()
        }
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFit()
        }
    }

    private func makePanel(engine: DictationEngine) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.holdSize.width, height: Self.holdSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false

        let root = NSView(frame: NSRect(origin: .zero, size: Self.holdSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let hosting = NSHostingView(rootView: IslandContent(engine: engine))
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]

        let hold = Self.makeHoldPill()
        hold.frame = NSRect(origin: .zero, size: Self.holdSize)
        hold.isHidden = true

        root.addSubview(hosting)
        root.addSubview(hold)
        panel.contentView = root

        self.root = root
        self.hosting = hosting
        self.holdPill = hold
        self.panel = panel
        parkInvisible()
    }

    /// AppKit Hold pill, shown on the same run-loop turn as the key-down.
    func revealHold() {
        guard islandAllowed, let panel, let holdPill, let hosting else { return }
        showingHold = true
        holdPill.isHidden = false
        hosting.alphaValue = 0
        if panel.frame.size != Self.holdSize {
            applySize(Self.holdSize)
        } else {
            reposition()
        }
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func revealLive() {
        guard islandAllowed, let panel, let holdPill, let hosting else { return }
        showingHold = false
        holdPill.isHidden = true
        hosting.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        resizeToFit()
    }

    func flushPresentation() {
        CATransaction.flush()
        panel?.displayIfNeeded()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if showingHold {
                revealHold()
            } else {
                revealLive()
            }
        } else {
            parkInvisible()
        }
    }

    private func parkInvisible() {
        showingHold = false
        holdPill?.isHidden = true
        hosting?.alphaValue = 1
        guard let panel else { return }
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        if islandAllowed, !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private var islandAllowed: Bool {
        ProcessInfo.processInfo.environment["WD_PREVIEW_ISLAND"] == "1"
            || AppSettings.shared.islandEnabled
    }

    func resizeToFit() {
        guard let hosting else { return }
        if showingHold {
            applySize(Self.holdSize)
            return
        }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if !size.width.isFinite || !size.height.isFinite || size.width > 260 || size.height > 48 {
            size = NSSize(width: 148, height: 32)
        }
        size.width = max(64, size.width)
        size.height = max(24, size.height)
        applySize(size)
    }

    func reposition() {
        guard let panel else { return }
        guard let screen = Self.activeScreen() else { return }
        panel.setFrameOrigin(IslandPlacement.origin(in: screen.visibleFrame, size: panel.frame.size))
    }

    private func applySize(_ size: NSSize) {
        guard let panel, let root else { return }
        panel.setContentSize(size)
        root.frame = NSRect(origin: .zero, size: size)
        hosting?.frame = root.bounds
        if let holdPill {
            holdPill.frame = NSRect(
                x: (size.width - Self.holdSize.width) / 2,
                y: (size.height - Self.holdSize.height) / 2,
                width: Self.holdSize.width,
                height: Self.holdSize.height
            )
        }
        reposition()
    }

    private static func makeHoldPill() -> NSView {
        let pill = NSView(frame: NSRect(origin: .zero, size: holdSize))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        pill.layer?.cornerRadius = holdSize.height / 2
        pill.layer?.masksToBounds = true

        let dot = NSView(frame: NSRect(x: 11, y: (holdSize.height - 6) / 2, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = 3
        pill.addSubview(dot)

        let label = NSTextField(labelWithString: "Hold")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = false
        label.isBordered = false
        label.isBezeled = false
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 24, y: (holdSize.height - label.frame.height) / 2))
        pill.addSubview(label)
        return pill
    }

    static func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let index = screens.firstIndex(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }

    private func listenForScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resizeToFit()
            self?.reposition()
        }
    }

    private func listenForActiveScreen() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.reposition()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.reposition()
            return event
        }
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }
}

private struct IslandContent: View {
    let engine: DictationEngine
    @State private var recordingStartedAt: Date?

    var body: some View {
        IslandPill(
            state: engine.state,
            isHolding: engine.isHoldingForToggle,
            isAutoHold: engine.isAutoHoldRecording,
            startedAt: recordingStartedAt,
            inputLevels: engine.inputLevels
        )
        .onTapGesture { engine.requestFinish() }
        .onChange(of: engine.state) { _, new in
            if new == .recording {
                recordingStartedAt = Date()
            } else if new == .idle {
                recordingStartedAt = nil
            }
            IslandController.shared.resizeToFit()
            IslandController.shared.reposition()
        }
        .fixedSize()
    }
}

private struct IslandPill: View {
    let state: DictationState
    let isHolding: Bool
    let isAutoHold: Bool
    let startedAt: Date?
    let inputLevels: [Float]

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            if isHolding {
                WaveformBars(color: .orange.opacity(0.9), levels: Array(repeating: 0, count: AudioCapture.visualizerBars))
            } else if state == .recording {
                elapsedLabel
                WaveformBars(color: .white.opacity(0.92), levels: inputLevels)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.72)))
    }

    private var dotColor: Color {
        if isHolding { return .orange }
        switch state {
        case .idle: return .gray
        case .recording: return .red
        case .processing: return .orange
        case .typing: return .blue
        }
    }

    private var title: String {
        if isHolding { return "Hold" }
        switch state {
        case .recording: return isAutoHold ? "Hold" : "Listening"
        case .processing: return "Transcribing"
        case .typing: return "Typing"
        case .idle: return "Ready"
        }
    }

    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt ?? context.date)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct WaveformBars: View {
    let color: Color
    let levels: [Float]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, rms in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: Self.height(for: rms))
            }
        }
        .frame(height: 12, alignment: .center)
        .animation(.easeOut(duration: 0.07), value: levels)
    }

    static func height(for rms: Float) -> CGFloat {
        let floor: Float = 0.006
        let ceiling: Float = 0.16
        let x = max(0, min(1, (rms - floor) / (ceiling - floor)))
        return 3 + CGFloat(pow(Double(x), 0.55)) * 9
    }
}
