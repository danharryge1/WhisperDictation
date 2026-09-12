import Foundation

@main
struct StandaloneChecks {
    static func main() {
        var failed = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                failed += 1
            }
        }

        let first = TranscriptHistory.recording("first", into: [])
        let second = TranscriptHistory.recording("second", into: first)
        check("newest first", second.map(\.text) == ["second", "first"])
        check("skip blank", TranscriptHistory.recording("   \n", into: []).isEmpty)
        check("skip consecutive dup", TranscriptHistory.recording("same", into: TranscriptHistory.recording("same", into: [])).count == 1)

        var items: [TranscriptHistory.Entry] = []
        for i in 1...7 { items = TranscriptHistory.recording("item \(i)", into: items) }
        check("cap at five", items.map(\.text) == ["item 7", "item 6", "item 5", "item 4", "item 3"])

        let encoded = try! JSONEncoder().encode(items)
        let decoded = try! JSONDecoder().decode([TranscriptHistory.Entry].self, from: encoded)
        check("json roundtrip", decoded.map(\.text) == items.map(\.text))

        let visible = CGRect(x: 100, y: 50, width: 1440, height: 850)
        let size = CGSize(width: 148, height: 32)
        let origin = IslandPlacement.origin(in: visible, size: size)
        check("island x centred", origin.x == visible.origin.x + (visible.size.width - size.width) / 2)
        check("island y bottom", origin.y == visible.origin.y + IslandPlacement.bottomMargin)
        check("bottom margin 18", IslandPlacement.bottomMargin == 18)

        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 2560, height: 1080)
        check("mouse on left screen", IslandPlacement.frame(containing: CGPoint(x: 900, y: 100), in: [left, right]) == left)
        check("mouse on right screen", IslandPlacement.frame(containing: CGPoint(x: 2500, y: 100), in: [left, right]) == right)
        check("mouse off screens", IslandPlacement.frame(containing: CGPoint(x: -20, y: 100), in: [left, right]) == nil)

        if failed > 0 {
            fputs("\(failed) check(s) failed\n", stderr)
            exit(1)
        }
        print("All standalone checks passed")
    }
}
