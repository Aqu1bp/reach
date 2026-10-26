import AppKit

/// Process entry point: debug commands run and exit; otherwise the menu bar app starts.
///
/// - `--self-test`: runs the pure-logic checks and exits 0/1.
/// - `--render-snapshots <dir>`: renders every UI state to PNGs in `dir` and exits.
@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let index = arguments.firstIndex(of: "--render-snapshots") {
            let directory = arguments.indices.contains(index + 1) ? arguments[index + 1] : "snapshots"
            exit(SnapshotRenderer.render(to: URL(fileURLWithPath: directory, isDirectory: true)) ? 0 : 1)
        }
        ReachHostApp.main()
    }
}
