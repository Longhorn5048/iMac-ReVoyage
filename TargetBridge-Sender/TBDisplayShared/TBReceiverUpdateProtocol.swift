import CryptoKit
import Foundation

enum TBReceiverUpdateProtocol {
    static let port: UInt16 = 54324
    static let maximumPackageBytes = 96 * 1024 * 1024
    enum Failure: Error { case invalidPackage, invalidResponse, unavailable, transferFailed, resultUnknown }

    struct Package: Sendable {
        let url: URL
        let size: Int
        let sha256: String
        static func prepare(_ url: URL) throws -> Package {
            // URL resource values may cache an earlier size if the file changed.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard url.pathExtension.lowercased() == "zip", attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
                  size <= maximumPackageBytes else { throw Failure.invalidPackage }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hash = SHA256()
            var read = 0
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                read += data.count
                guard read <= size else { throw Failure.invalidPackage }
                hash.update(data: data)
            }
            guard read == size else { throw Failure.invalidPackage }
            return Package(url: url, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        func header(host: String, requestID: UUID) -> Data {
            Data("POST /update HTTP/1.1\r\nHost: \(host)\r\nContent-Length: \(size)\r\nX-ReVoyage-SHA256: \(sha256)\r\nX-ReVoyage-Request-ID: \(requestID.uuidString)\r\nConnection: close\r\n\r\n".utf8)
        }
    }

    struct Status: Decodable, Sendable, Equatable {
        let `protocol`: Int
        let phase: String
        let requestID: String?
        let progress: Double
        let error: String
        let receiverBuild: String?
        let receiverID: String?
        var isValid: Bool {
            self.protocol == 1 && ["idle", "receiving", "validating", "installing", "completed", "failed"].contains(phase)
                && progress.isFinite && (0...1).contains(progress)
                && (phase == "idle" || requestID.flatMap(UUID.init(uuidString:)) != nil)
        }
        func matches(requestID: String) -> Bool {
            isValid && self.requestID?.lowercased() == requestID.lowercased()
        }
    }

    struct ResponseDecoder {
        private var buffer = Data()
        mutating func receive(_ data: Data) throws -> (code: Int, body: Data)? {
            buffer.append(data)
            guard buffer.count <= 32 * 1024 else { throw Failure.invalidResponse }
            guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 8192 else { throw Failure.invalidResponse }
                return nil
            }
            guard split.lowerBound <= 8192, let header = String(data: buffer[..<split.lowerBound], encoding: .ascii) else { throw Failure.invalidResponse }
            let lines = header.components(separatedBy: "\r\n")
            let status = lines[0].split(separator: " ")
            guard status.count >= 2, status[0] == "HTTP/1.1", let code = Int(status[1]) else { throw Failure.invalidResponse }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidResponse }
                let key = line[..<colon].lowercased()
                guard fields[key] == nil else { throw Failure.invalidResponse }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil, let value = fields["content-length"],
                  !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int(value), (0...16384).contains(length) else { throw Failure.invalidResponse }
            let start = split.upperBound
            guard buffer.count >= start + length else { return nil }
            guard buffer.count == start + length else { throw Failure.invalidResponse }
            return (code, buffer.subdata(in: start..<(start + length)))
        }
    }
}
