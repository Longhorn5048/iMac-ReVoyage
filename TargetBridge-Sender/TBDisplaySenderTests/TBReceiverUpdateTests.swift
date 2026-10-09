import XCTest
@testable import TargetBridge

final class TBReceiverUpdateTests: XCTestCase {
    func testPackageDigestAndBoundedUploadHeaders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("update.zip")
        try Data("abc".utf8).write(to: url)
        let package = try TBReceiverUpdateProtocol.Package.prepare(url)
        XCTAssertEqual(package.size, 3)
        XCTAssertEqual(package.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let id = UUID()
        let header = String(decoding: package.header(host: "169.254.1.2", requestID: id), as: UTF8.self)
        XCTAssertTrue(header.contains("Content-Length: 3\r\n"))
        XCTAssertTrue(header.contains("X-ReVoyage-Request-ID: \(id.uuidString)\r\n"))
        XCTAssertTrue(header.hasSuffix("\r\n\r\n"))
        let wrong = root.appendingPathComponent("update.txt")
        try Data("abc".utf8).write(to: wrong)
        XCTAssertThrowsError(try TBReceiverUpdateProtocol.Package.prepare(wrong))
        try Data().write(to: url)
        XCTAssertThrowsError(try TBReceiverUpdateProtocol.Package.prepare(url))
        let output = try FileHandle(forWritingTo: url)
        try output.truncate(atOffset: UInt64(TBReceiverUpdateProtocol.maximumPackageBytes + 1))
        try output.close()
        XCTAssertThrowsError(try TBReceiverUpdateProtocol.Package.prepare(url))
    }

    func testResponseDecoderHandlesEverySplit() throws {
        let body = Data("{\"phase\":\"completed\"}".utf8)
        let packet = Data("HTTP/1.1 200 Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        for split in 0..<packet.count {
            var decoder = TBReceiverUpdateProtocol.ResponseDecoder()
            XCTAssertNil(try decoder.receive(packet.prefix(split)))
            let response = try XCTUnwrap(decoder.receive(packet.dropFirst(split)))
            XCTAssertEqual(response.code, 200)
            XCTAssertEqual(response.body, body)
        }
    }

    func testResponseDecoderRejectsAmbiguousAndUnboundedReplies() {
        for header in ["Content-Length: -1", "Content-Length: 16385", "Content-Length: 1\r\nContent-Length: 1",
                       "Transfer-Encoding: chunked\r\nContent-Length: 0", "Content-Length: abc"] {
            var decoder = TBReceiverUpdateProtocol.ResponseDecoder()
            XCTAssertThrowsError(try decoder.receive(Data("HTTP/1.1 200 Response\r\n\(header)\r\n\r\n".utf8)))
        }
        var decoder = TBReceiverUpdateProtocol.ResponseDecoder()
        XCTAssertThrowsError(try decoder.receive(Data(repeating: 65, count: 8193)))
        decoder = .init()
        XCTAssertThrowsError(try decoder.receive(Data("HTTP/1.1 200 Response\r\nContent-Length: 1\r\n\r\nxx".utf8)))
    }

    func testUpdateReceiptCannotConfirmAnotherRequest() throws {
        let id = UUID().uuidString
        func status(_ phase: String, _ progress: Double, _ request: String? = nil, _ version: Int = 1) throws -> TBReceiverUpdateProtocol.Status {
            var fields: [String: Any] = ["protocol":version, "phase":phase, "progress":progress, "error":""]
            fields["requestID"] = request
            return try JSONDecoder().decode(TBReceiverUpdateProtocol.Status.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let completed = try status("completed", 1, id)
        XCTAssertTrue(completed.matches(requestID: id.lowercased()))
        XCTAssertFalse(completed.matches(requestID: UUID().uuidString))
        XCTAssertTrue(try status("idle", 0).isValid)
        XCTAssertFalse(try status("completed", 1).isValid)
        XCTAssertFalse(try status("installing", 1, "invalid").isValid)
        XCTAssertFalse(try status("installing", 1.1, id).isValid)
        XCTAssertFalse(try status("unknown", 0, id).isValid)
        XCTAssertFalse(try status("idle", 0, nil, 2).isValid)
    }
}
