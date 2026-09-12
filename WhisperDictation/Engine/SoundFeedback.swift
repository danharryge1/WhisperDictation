import AppKit

final class SoundFeedback {
    private var clickA: NSSound?
    private var clickB: NSSound?
    private var doneSound: NSSound?
    private var useA = true

    init() {
        clickA = NSSound(named: "Tink")
        clickB = NSSound(named: "Tink")
        doneSound = NSSound(named: "Purr")
    }

    var isEnabled: Bool {
        AppSettings.shared.soundFeedbackEnabled
    }

    func playStartSound() {
        playClickSound()
    }

    func playStopSound() {
        playClickSound()
    }

    func playDoneSound() {
        guard isEnabled else { return }
        doneSound?.stop()
        doneSound?.play()
    }

    private func playClickSound() {
        guard isEnabled else { return }
        let sound = useA ? clickA : clickB
        useA.toggle()
        sound?.play()
    }
}
