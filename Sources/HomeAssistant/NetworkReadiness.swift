import Foundation
import Network

/// Checks whether the Mac actually has usable network connectivity.
///
/// On a cold boot / login the menu-bar app launches very early — often *before*
/// the network interface is up and DNS resolves. Home Assistant then starts
/// into a network-less window: LAN integrations report "Network is unreachable"
/// and cloud integrations (easee, octopus, …) fail DNS ("Could not contact DNS
/// servers"). Integrations with bounded setup-retries exhaust them in that
/// window and stay dead until a manual reload.
///
/// `ServerController` gates the launch on `isReady()`: an interface must be
/// `.satisfied` *and* a real TCP+DNS probe to a stable host must succeed, so we
/// only start once the network is genuinely usable (bounded by a timeout in the
/// caller, so an offline Mac still starts eventually and HA's own retry takes
/// over).
enum NetworkReadiness {

    /// Single-resume guard so a continuation is never resumed twice (the NW
    /// state handler and the timeout can both fire).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// Well-known, rarely-blocked hosts used to confirm real DNS + internet
    /// reachability. Success on *any* of them counts — so a single blocked
    /// provider can't wedge the gate into the timeout on every start.
    private static let probeHosts = ["one.one.one.one", "www.apple.com", "dns.google"]

    /// True when an interface is up *and* at least one stable host is reachable
    /// (which proves DNS resolves and the internet is routable).
    static func isReady(port: UInt16 = 443) async -> Bool {
        guard await interfaceUp() else { return false }
        return await reachableAny(hosts: probeHosts, port: port, timeout: 5)
    }

    /// Probe several hosts concurrently; return true as soon as one connects.
    private static func reachableAny(hosts: [String], port: UInt16, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for host in hosts {
                group.addTask { await canReach(host: host, port: port, timeout: timeout) }
            }
            for await ok in group where ok {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    /// Wait briefly for `NWPathMonitor` to report a `.satisfied` path.
    static func interfaceUp(timeout: TimeInterval = 3) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ha.net.path")
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            monitor.pathUpdateHandler = { path in
                if once.fire() {
                    monitor.cancel()
                    cont.resume(returning: path.status == .satisfied)
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() {
                    monitor.cancel()
                    cont.resume(returning: false)
                }
            }
            monitor.start(queue: queue)
        }
    }

    /// Resolve + TCP-connect to `host:port`; success means DNS works and the
    /// host is reachable. Uses the Network framework so it honours the system
    /// resolver and routing exactly like Home Assistant's aiohttp will.
    static func canReach(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let queue = DispatchQueue(label: "ha.net.probe")
        let once = Once()
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled:
                    if once.fire() { conn.cancel(); cont.resume(returning: false) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() { conn.cancel(); cont.resume(returning: false) }
            }
            conn.start(queue: queue)
        }
    }
}
