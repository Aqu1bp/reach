import Foundation
import ReachCore
import ReachProtocol

// reach-probe — end-to-end test tool for Reach.
//
//   reach-probe host [--size WxH] [--policy all|relay|nohost] [--turn url,user,pass]
//       Run a real HostEngine with a synthetic, input-reactive screen. Prints PAIRING_URL.
//   reach-probe pair <reach://pair?...>
//   reach-probe probe
//   reach-probe connect [--seconds N] [--policy relay|nohost] [--input-test] [--snapshot out.png]
//                       [--quality sharp|balanced|smooth|dataSaver] [--fps N]
//   reach-probe bench [--size WxH] [--fps N] [--scenario bursts|continuous] [--content text|video|desktop]
//                     [--idle S] [--motion S]
//                     [--cycles N] [--settle S] [--step PT] [--quality sharp|balanced|smooth|dataSaver]
//                     [--policy all|relay|nohost] [--label NAME] [--report out.json] [--verbose]
//       Host + client in one process over an in-process relay; measures push → decode latency of
//       scrolling bursts and writes a JSON report (see Tools/README-bench.md).
//
// State lives in ./.reach-probe/<role> (override with --state DIR).

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: reach-probe host|pair|probe|connect|bench [options]")
    exit(2)
}
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

if flag("--verbose") { ReachLog.echoToStderr = true }

let role = command == "host" ? "host" : "client"
let stateDir = URL(fileURLWithPath: option("--state") ?? ".reach-probe/\(role)", isDirectory: true)
if command != "bench" { try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true) }

switch command {
case "host":
    let size = (option("--size") ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
    var turn: IceServerConfig?
    if let t = option("--turn") {
        let parts = t.split(separator: ",").map(String.init)
        turn = IceServerConfig(urls: [parts[0]], username: parts.count > 1 ? parts[1] : nil, credential: parts.count > 2 ? parts[2] : nil)
    }
    do {
        let host = try ProbeHost(state: stateDir, width: size.first ?? 3024, height: size.last ?? 1964,
                                 policy: option("--policy"), turn: turn)
        host.run(pairingURLFile: stateDir.appendingPathComponent("pairing-url.txt"))
        withExtendedLifetime(host) { RunLoop.main.run() }
    } catch {
        print("host failed: \(error)")
        exit(1)
    }

case "pair":
    guard let url = args.first(where: { $0.hasPrefix("reach://") }) else { print("usage: reach-probe pair <url>"); exit(2) }
    let client = try ProbeClient(state: stateDir)
    exit(client.pair(url) ? 0 : 1)

case "probe":
    let client = try ProbeClient(state: stateDir)
    client.probe()

case "connect":
    let client = try ProbeClient(state: stateDir)
    var opt = ProbeClient.Options()
    opt.seconds = Double(option("--seconds") ?? "10") ?? 10
    opt.policy = option("--policy")
    opt.snapshot = option("--snapshot")
    opt.inputTest = flag("--input-test")
    if let q = option("--quality"), let m = QualityMode(rawValue: q) { opt.quality.mode = m }
    if let f = option("--fps"), let n = Int(f) { opt.quality.maxFramesPerSecond = n }
    exit(client.connect(opt) ? 0 : 1)

case "bench":
    var opt = BenchOptions()
    if let v = option("--size") {
        let wh = v.lowercased().split(separator: "x").compactMap { Int($0) }
        guard wh.count == 2, wh[0] > 0, wh[1] > 0 else { print("bad --size \(v) (want WxH)"); exit(2) }
        opt.width = wh[0]; opt.height = wh[1]
    }
    if let v = option("--fps"), let n = Int(v), n > 0 { opt.fps = n }
    if let v = option("--scenario") {
        guard v == "bursts" || v == "continuous" else { print("bad --scenario \(v) (bursts|continuous)"); exit(2) }
        opt.scenario = v
    }
    if let v = option("--content") {
        guard ["text", "video", "desktop"].contains(v) else { print("bad --content \(v) (text|video|desktop)"); exit(2) }
        opt.content = v
    }
    if let v = option("--idle"), let d = Double(v), d >= 0 { opt.idle = d }
    if let v = option("--motion"), let d = Double(v), d > 0 { opt.motion = d }
    if let v = option("--cycles"), let n = Int(v), n > 0 { opt.cycles = n }
    if let v = option("--settle"), let d = Double(v), d >= 0 { opt.settle = d }
    if let v = option("--step"), let d = Double(v), d > 0 { opt.step = d }
    if let v = option("--quality") {
        guard let m = QualityMode(rawValue: v) else { print("bad --quality \(v)"); exit(2) }
        opt.quality = m
    }
    opt.policy = option("--policy")
    opt.reportPath = option("--report")
    opt.label = option("--label")
    let bench = BenchRunner(opt)
    exit(bench.run() ? 0 : 1)

default:
    print("unknown command \(command)")
    exit(2)
}
