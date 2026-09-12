import AppKit
import CoreGraphics
import Foundation

@main
struct VerifyLive {
    static func main() throws {
        let suite = UserDefaults(suiteName: "com.sampop.WhisperDictation")!

        enum Mode: String {
            case seedHistory, readHistory, restoreHistory, copyClipboard, listWindows
        }

        let mode = Mode(rawValue: CommandLine.arguments.dropFirst().first ?? "") ?? .listWindows

        switch mode {
        case .seedHistory:
            let existing = suite.data(forKey: "transcriptHistory")
            if let existing {
                suite.set(existing, forKey: "transcriptHistory.backup")
            } else {
                suite.removeObject(forKey: "transcriptHistory.backup")
            }
            var items: [TranscriptHistory.Entry] = []
            for text in ["fifth", "fourth", "third", "second", "first"] {
                items = TranscriptHistory.recording(text, into: items)
            }
            items = TranscriptHistory.recording("newest", into: items)
            suite.set(try JSONEncoder().encode(items), forKey: "transcriptHistory")
            suite.synchronize()
            print("seeded \(items.count) \(items.map(\.text).joined(separator: "|"))")

        case .readHistory:
            guard let data = suite.data(forKey: "transcriptHistory") else {
                print("HISTORY_EMPTY")
                return
            }
            let items = try JSONDecoder().decode([TranscriptHistory.Entry].self, from: data)
            print("count=\(items.count)")
            print(items.map(\.text).joined(separator: "|"))

        case .restoreHistory:
            if let backup = suite.data(forKey: "transcriptHistory.backup") {
                suite.set(backup, forKey: "transcriptHistory")
                print("restored backup")
            } else {
                suite.removeObject(forKey: "transcriptHistory")
                print("cleared history")
            }
            suite.removeObject(forKey: "transcriptHistory.backup")
            suite.synchronize()

        case .copyClipboard:
            let marker = "wd-clipboard-verify-\(Int(Date().timeIntervalSince1970))"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(marker, forType: .string)
            let got = NSPasteboard.general.string(forType: .string)
            guard got == marker else {
                fputs("clipboard write failed got=\(got ?? "nil")\n", stderr)
                exit(1)
            }
            print(marker)

        case .listWindows:
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as! [[String: Any]]
            var found = 0
            for w in raw {
                let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                guard owner.contains("WhisperDictation") else { continue }
                found += 1
                let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                let number = w[kCGWindowNumber as String] as? Int ?? 0
                let alpha = w[kCGWindowAlpha as String] as? CGFloat ?? 1
                print("id=\(number) layer=\(layer) alpha=\(alpha) bounds=\(bounds)")
            }
            if found == 0 { print("NO_WINDOWS") }
        }
    }
}
