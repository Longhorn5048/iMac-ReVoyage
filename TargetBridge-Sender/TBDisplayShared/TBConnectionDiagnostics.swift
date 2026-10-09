import Foundation
import Network
import SystemConfiguration
import os

/// Unified-logging entry points for the sender. `log stream --predicate
/// 'subsystem == "com.targetbridge.sender"'` (or Console.app) shows the
/// connection lifecycle without attaching a debugger.
enum TBLog {
    static let connection = Logger(subsystem: "com.targetbridge.sender", category: "connection")
}

/// Pure helpers for deciding how to dial a receiver and for composing
/// actionable connection-failure details. Kept free of session state so the
/// unit-test bundle can exercise them without hardware.
enum TBConnectionDiagnostics {

    /// A local IPv4 interface as (name, ip) — the test-injectable slice of
    /// what `getifaddrs` reports.
    struct LocalInterface: Equatable {
        let name: String
        let ip: String
        let netmask: String?

        init(name: String, ip: String, netmask: String? = nil) {
            self.name = name
            self.ip = ip
            self.netmask = netmask
        }
    }

    /// Returns the name of the local interface that owns `localIP`, if any.
    static func interfaceName(forLocalIP localIP: String, in interfaces: [LocalInterface]) -> String? {
        guard !localIP.isEmpty else { return nil }
        return interfaces.first(where: { $0.ip == localIP })?.name
    }

    /// For a link-local (`169.254.x`) receiver address, returns
    /// `"<ip>%<interface>"` so the dial is scoped to the interface that owns
    /// `localIP`. Everything else is returned unchanged.
    ///
    /// Why: macOS keeps a single routing-table entry for all of
    /// 169.254.0.0/16, pointing at the primary interface (usually Wi-Fi). A
    /// Thunderbolt Bridge peer is only reachable on the bridge interface, so
    /// an unscoped dial to its self-assigned link-local address leaves via the
    /// wrong interface and times out — with both Macs configured correctly.
    /// A scoped address routes on the named interface regardless of the table.
    static func scopedReceiverHost(
        receiverIP: String,
        localIP: String,
        interfaces: [LocalInterface]
    ) -> String {
        guard receiverIP.hasPrefix("169.254."), !receiverIP.contains("%") else { return receiverIP }
        guard let name = interfaceName(forLocalIP: localIP, in: interfaces) else { return receiverIP }
        return "\(receiverIP)%\(name)"
    }

    /// Human-readable context for a failed or timed-out connect attempt:
    /// where we dialed, from which address/interface, over which transport,
    /// and the last state reported by the network stack.
    static func failureDetail(
        receiverHost: String,
        port: UInt16,
        localIP: String,
        interfaceName: String?,
        transport: String,
        lastNetworkState: String?
    ) -> String {
        var detail = "dialed \(receiverHost):\(port) from \(localIP)"
        if let interfaceName, !interfaceName.isEmpty {
            detail += " (\(interfaceName))"
        }
        detail += " [\(transport)]"
        if let lastNetworkState, !lastNetworkState.isEmpty {
            detail += " — last network state: \(lastNetworkState)"
        }
        return detail
    }

    /// Snapshot of the machine's up, non-loopback IPv4 interfaces.
    static func currentIPv4Interfaces() -> [LocalInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [LocalInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: buffer)
            var netmask: String?
            if let mask = iface.pointee.ifa_netmask,
               getnameinfo(mask, socklen_t(mask.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                netmask = String(cString: buffer)
            }
            interfaces.append(LocalInterface(name: String(cString: iface.pointee.ifa_name), ip: ip, netmask: netmask))
        }
        return interfaces
    }
}

/// All display and auxiliary services use the same verified wired route.
/// Bridge membership comes from macOS configuration, not BSD name prefixes.
enum TBWiredConnection {
    enum Failure: Error { case wiredInterfaceRequired, linkTooSlow }
    struct Link: Equatable {
        let name: String
        let ip: String
        let mbps: Int
        let netmask: String?
        init(name: String, ip: String, mbps: Int, netmask: String? = nil) {
            self.name = name; self.ip = ip; self.mbps = mbps; self.netmask = netmask
        }
    }
    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let value = UInt32(part), value <= 255 else { return nil }
            result = (result << 8) | value
        }
        return result
    }
    static func isWired(name: String, types: [String: String], bridges: [String: [String]]) -> Bool {
        if types[name] == "Ethernet" { return true }
        guard types[name] == "Bridge", let members = bridges[name], !members.isEmpty else { return false }
        return members.allSatisfy { types[$0] == "Ethernet" }
    }
    static func currentLinks() -> [Link] {
        guard let rows = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var types: [String: String] = [:]
        for row in rows {
            if let name = SCNetworkInterfaceGetBSDName(row) as String?,
               let type = SCNetworkInterfaceGetInterfaceType(row) as String? { types[name] = type }
        }
        var bridges: [String: [String]] = [:]
        if let prefs = SCPreferencesCreate(nil, "ReVoyage wired routes" as CFString, nil),
           let virtual = SCPreferencesGetValue(prefs, "VirtualNetworkInterfaces" as CFString) as? [String: Any],
           let configurations = virtual["Bridge"] as? [String: [String: Any]] {
            for (name, value) in configurations { bridges[name] = value["Interfaces"] as? [String] }
        }
        return TBConnectionDiagnostics.currentIPv4Interfaces().compactMap { interface in
            guard isWired(name: interface.name, types: types, bridges: bridges) else { return nil }
            let members = bridges[interface.name] ?? [interface.name]
            let knownSpeeds = members.map { Int(tb_network_link_mbps($0)) }.filter { $0 > 0 }
            return Link(name: interface.name, ip: interface.ip, mbps: knownSpeeds.min() ?? 0, netmask: interface.netmask)
        }
    }
    static func select(host: String, localIP: String?, links: [Link]) throws -> Link {
        let link: Link?
        if let localIP, !localIP.isEmpty {
            link = links.first { $0.ip == localIP }
        } else {
            let matches = links.filter { candidate in
                let maskText = candidate.netmask ?? (candidate.ip.hasPrefix("169.254.") ? "255.255.0.0" : "255.255.255.0")
                guard let remote = ipv4(host), let local = ipv4(candidate.ip), let mask = ipv4(maskText) else { return false }
                return (remote & mask) == (local & mask)
            }
            link = matches.count == 1 ? matches.first : (links.count == 1 ? links.first : nil)
        }
        guard let link else { throw Failure.wiredInterfaceRequired }
        guard link.mbps == 0 || link.mbps >= 1000 else { throw Failure.linkTooSlow }
        return link
    }
    static func dial(host: String, localIP: String? = nil) throws -> (NWEndpoint.Host, NWParameters) {
        let link = try select(host: host, localIP: localIP, links: currentLinks())
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(link.ip), port: .any)
        let scoped = TBConnectionDiagnostics.scopedReceiverHost(receiverIP: host, localIP: link.ip,
            interfaces: [.init(name: link.name, ip: link.ip)])
        if scoped != host, let ip = IPv4Address(scoped) { return (.ipv4(ip), parameters) }
        return (NWEndpoint.Host(host), parameters)
    }
}
