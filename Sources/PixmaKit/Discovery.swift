import Foundation
import Network
import Darwin

public struct DiscoveredScanner: Hashable, Sendable, Identifiable {
    public var id: String { host }
    public let name: String
    /// Hostname or IP address usable with `BJNPConnection`.
    public let host: String
    public let source: String

    public init(name: String, host: String, source: String) {
        self.name = name; self.host = host; self.source = source
    }
}

/// Finds Canon network scanners.
///
/// 1. Bonjour: PIXMA devices advertise `_scanner._tcp` (port 8612) and `_canon-bjnp1._tcp`.
///    Browsing goes through mDNSResponder, so it is not affected by the application firewall.
/// 2. Subnet sweep: a BJNP "discover" datagram to every address of each local /22-or-smaller IPv4
///    subnet, using *connected* UDP sockets. A plain broadcast would be simpler, but the macOS
///    application firewall drops the unsolicited replies for apps that are not Developer-ID signed;
///    replies on a connected socket count as part of an outgoing flow and are let through.
public final class ScannerDiscovery: @unchecked Sendable {
    public init() {}

    public func discover(timeout: TimeInterval = 3) async -> [DiscoveredScanner] {
        async let bonjour = browseBonjour(timeout: timeout)
        async let sweep = Task.detached { Self.sweepSubnets(timeout: min(timeout, 2)) }.value
        var byHost: [String: DiscoveredScanner] = [:]
        for s in await bonjour { byHost[s.host] = s }
        for s in await sweep where byHost[s.host] == nil { byHost[s.host] = s }
        return byHost.values.sorted { $0.name < $1.name }
    }

    // MARK: Bonjour

    /// IPv4 addresses of devices that offer driverless scanning (AirScan / eSCL). macOS's Image
    /// Capture handles those itself, so they don't need the native PIXMA driver.
    public func airScanHosts(timeout: TimeInterval = 3) async -> Set<String> {
        Set(await browseBonjour(types: ["_uscan._tcp", "_uscans._tcp"], canonOnly: false, timeout: timeout).map(\.host))
    }

    private func browseBonjour(timeout: TimeInterval) async -> [DiscoveredScanner] {
        await browseBonjour(types: ["_scanner._tcp", "_canon-bjnp1._tcp"], canonOnly: true, timeout: timeout)
    }

    private func browseBonjour(types: [String], canonOnly: Bool, timeout: TimeInterval) async -> [DiscoveredScanner] {
        let found = LockedBox<[String: DiscoveredScanner]>([:])
        let connections = LockedBox<[NWConnection]>([])
        let queue = DispatchQueue(label: "elva.bonjour")
        var browsers: [NWBrowser] = []

        for type in types {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .udp)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    if canonOnly, case let .bonjour(txt) = result.metadata,
                       let mfg = txt.dictionary["mfg"], !mfg.localizedCaseInsensitiveContains("canon") {
                        continue
                    }
                    // Resolve to an IPv4 address by opening a UDP flow (no packets are sent).
                    let params = NWParameters.udp
                    if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                        ip.version = .v4
                    }
                    let conn = NWConnection(to: result.endpoint, using: params)
                    conn.stateUpdateHandler = { state in
                        guard case .ready = state else { return }
                        if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                            var h = "\(host)"
                            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                            if !h.contains(":") {
                                found.mutate { $0[h] = DiscoveredScanner(name: name, host: h, source: "Bonjour") }
                            }
                        }
                        conn.cancel()
                    }
                    connections.mutate { $0.append(conn) }
                    conn.start(queue: queue)
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        try? await Task.sleep(for: .seconds(timeout))
        browsers.forEach { $0.cancel() }
        connections.value.forEach { $0.cancel() }
        return Array(found.value.values)
    }

    // MARK: Subnet sweep

    /// IPv4 hosts on the Mac's active interfaces (skipping loopback and subnets larger than /22).
    static func localSubnetHosts() -> [in_addr_t] {
        var hosts = Set<in_addr_t>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let nm = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let size = ~nm
            guard size > 1, size <= 1023 else { continue }
            let network = ip & nm
            for i in 1..<size where network | i != ip {
                hosts.insert((network | i).bigEndian)
            }
        }
        return Array(hosts)
    }

    public static func sweepSubnets(timeout: TimeInterval) -> [DiscoveredScanner] {
        // Batches keep us well below the default 256 open-file limit.
        let hosts = localSubnetHosts().sorted()
        let batch = 128
        let perBatch = max(0.4, timeout / Double(max(1, (hosts.count + batch - 1) / batch)))
        var responders: [in_addr_t] = []
        for start in stride(from: 0, to: hosts.count, by: batch) {
            responders += probe(Array(hosts[start..<min(hosts.count, start + batch)]), timeout: perBatch)
        }
        return responders.map { addr in
            var a = in_addr(s_addr: addr)
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &ip, socklen_t(ip.count))
            let host = String(cString: ip)
            var name = "Canon scanner (\(host))"
            if let conn = try? BJNPConnection(host: host, timeout: 2),
               let id = try? conn.identity(),
               let mdl = IEEE1284.fields(id)["MDL"] {
                name = "Canon \(mdl)"
            }
            return DiscoveredScanner(name: name, host: host, source: "Network sweep")
        }
    }

    /// Sends a BJNP discover to each host and returns those that answered.
    static func probe(_ hosts: [in_addr_t], timeout: TimeInterval) -> [in_addr_t] {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 0x42; packet[1] = 0x4A; packet[2] = 0x4E; packet[3] = 0x50
        packet[4] = 0x02; packet[5] = 0x01   // scanner, discover

        var sockets: [(fd: Int32, addr: in_addr_t)] = []
        defer { sockets.forEach { close($0.fd) } }
        for host in hosts {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { break }   // out of descriptors: sweep what we have
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = BJNPConnection.scanPort.bigEndian
            dest.sin_addr.s_addr = host
            let rc = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard rc == 0 else { close(fd); continue }
            _ = send(fd, packet, packet.count, 0)
            sockets.append((fd, host))
        }

        var responders: [in_addr_t] = []
        var pending = sockets
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 512)
        while !pending.isEmpty, Date() < deadline {
            var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&fds, nfds_t(fds.count), remaining) > 0 else { break }
            var stillPending: [(fd: Int32, addr: in_addr_t)] = []
            for (i, p) in fds.enumerated() {
                if p.revents & Int16(POLLIN) != 0 {
                    let n = recv(p.fd, &buf, buf.count, 0)
                    if n >= 16, buf[0] == 0x42, buf[1] == 0x4A, buf[5] == 0x01, buf[4] & 0x80 != 0 {
                        responders.append(pending[i].addr)
                    }
                } else if p.revents == 0 {
                    stillPending.append(pending[i])
                }
            }
            pending = stillPending
        }
        return responders
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
