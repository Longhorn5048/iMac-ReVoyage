import XCTest
@testable import TargetBridge

/// Tests for the connect-path helpers: link-local interface scoping (the fix
/// for Thunderbolt Bridge dials leaving via the wrong interface) and the
/// failure-detail composer that keeps diagnostics attached to errors.
final class TBConnectionDiagnosticsTests: XCTestCase {

    private typealias Interface = TBConnectionDiagnostics.LocalInterface

    private let interfaces: [Interface] = [
        Interface(name: "en0", ip: "192.168.1.225"),
        Interface(name: "bridge0", ip: "169.254.109.86"),
    ]

    // MARK: - interfaceName(forLocalIP:)

    func testInterfaceNameFindsOwningInterface() {
        XCTAssertEqual(
            TBConnectionDiagnostics.interfaceName(forLocalIP: "169.254.109.86", in: interfaces),
            "bridge0"
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.interfaceName(forLocalIP: "192.168.1.225", in: interfaces),
            "en0"
        )
    }

    func testInterfaceNameNilForUnknownOrEmptyIP() {
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "10.0.0.1", in: interfaces))
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "", in: interfaces))
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "169.254.109.86", in: []))
    }

    // MARK: - scopedReceiverHost

    /// The Thunderbolt Bridge case: both ends self-assign 169.254.x, the
    /// routing table pins 169.254/16 to the primary interface, and only a
    /// scoped dial reaches the peer.
    func testLinkLocalReceiverIsScopedToOwningInterface() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80",
                localIP: "169.254.109.86",
                interfaces: interfaces
            ),
            "169.254.89.80%bridge0"
        )
    }

    func testNonLinkLocalReceiverIsNotScoped() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "192.168.1.64",
                localIP: "192.168.1.225",
                interfaces: interfaces
            ),
            "192.168.1.64"
        )
    }

    func testLinkLocalReceiverWithoutMatchingLocalInterfaceIsUnchanged() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80",
                localIP: "10.9.9.9",
                interfaces: interfaces
            ),
            "169.254.89.80"
        )
    }

    func testAlreadyScopedReceiverIsUnchanged() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80%bridge0",
                localIP: "169.254.109.86",
                interfaces: interfaces
            ),
            "169.254.89.80%bridge0"
        )
    }

    // MARK: - failureDetail

    func testFailureDetailIncludesFullContext() {
        let detail = TBConnectionDiagnostics.failureDetail(
            receiverHost: "169.254.89.80",
            port: 54321,
            localIP: "169.254.109.86",
            interfaceName: "bridge0",
            transport: "thunderboltBridge",
            lastNetworkState: "waiting(No route to host)"
        )
        XCTAssertEqual(
            detail,
            "dialed 169.254.89.80:54321 from 169.254.109.86 (bridge0) [thunderboltBridge] — last network state: waiting(No route to host)"
        )
    }

    func testFailureDetailOmitsMissingInterfaceAndState() {
        let detail = TBConnectionDiagnostics.failureDetail(
            receiverHost: "192.168.1.64",
            port: 54321,
            localIP: "192.168.1.225",
            interfaceName: nil,
            transport: "networkLink",
            lastNetworkState: nil
        )
        XCTAssertEqual(detail, "dialed 192.168.1.64:54321 from 192.168.1.225 [networkLink]")
    }

    // MARK: - currentIPv4Interfaces (live snapshot; environment-tolerant)

    func testCurrentIPv4InterfacesExcludesLoopbackAndHasNames() {
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        for iface in interfaces {
            XCTAssertFalse(iface.name.isEmpty)
            XCTAssertFalse(iface.ip.hasPrefix("127."), "loopback must be excluded, found \(iface.ip) on \(iface.name)")
        }
    }
}

final class TBWiredConnectionTests: XCTestCase {
    func testActualInterfaceTypesExcludeWiFiAndMixedBridges() {
        let types = ["en0": "IEEE80211", "en1": "Ethernet", "bridge0": "Bridge", "bridge1": "Bridge"]
        let bridges = ["bridge0": ["en1"], "bridge1": ["en0", "en1"]]
        XCTAssertFalse(TBWiredConnection.isWired(name: "en0", types: types, bridges: bridges))
        XCTAssertTrue(TBWiredConnection.isWired(name: "en1", types: types, bridges: bridges))
        XCTAssertTrue(TBWiredConnection.isWired(name: "bridge0", types: types, bridges: bridges))
        XCTAssertFalse(TBWiredConnection.isWired(name: "bridge1", types: types, bridges: bridges))
        XCTAssertFalse(TBWiredConnection.isWired(name: "bridge9", types: types, bridges: bridges))
    }
    func testSelectionUsesActualSubnetMask() throws {
        let ethernet = TBWiredConnection.Link(name: "en1", ip: "10.2.1.2", mbps: 1000, netmask: "255.255.0.0")
        let another = TBWiredConnection.Link(name: "en2", ip: "192.168.1.2", mbps: 1000, netmask: "255.255.255.0")
        XCTAssertEqual(try TBWiredConnection.select(host: "10.2.200.1", localIP: nil, links: [ethernet, another]), ethernet)
        XCTAssertThrowsError(try TBWiredConnection.select(host: "10.3.1.1", localIP: nil, links: [ethernet, another]))
    }
    func testMediaReusesSelectedDisplayRouteAndRejectsSlowOrMissingLink() throws {
        let ethernet = TBWiredConnection.Link(name: "en1", ip: "192.168.1.2", mbps: 1000)
        let thunderbolt = TBWiredConnection.Link(name: "bridge0", ip: "169.254.1.2", mbps: 0)
        XCTAssertEqual(try TBWiredConnection.select(host: "169.254.8.1", localIP: thunderbolt.ip, links: [ethernet, thunderbolt]), thunderbolt)
        XCTAssertEqual(try TBWiredConnection.select(host: "169.254.8.1", localIP: nil, links: [ethernet, thunderbolt]), thunderbolt)
        XCTAssertThrowsError(try TBWiredConnection.select(host: "192.168.1.1", localIP: "192.168.1.3", links: [ethernet]))
        XCTAssertThrowsError(try TBWiredConnection.select(host: "receiver.local", localIP: nil, links: [ethernet, thunderbolt]))
        XCTAssertThrowsError(try TBWiredConnection.select(host: "192.168.1.1", localIP: nil,
            links: [.init(name: "en1", ip: "192.168.1.2", mbps: 100)]))
    }
}
