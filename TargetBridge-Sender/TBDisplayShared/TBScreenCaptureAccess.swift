import Foundation
import ScreenCaptureKit

/// A failed CoreGraphics preflight is inconclusive for ScreenCaptureKit.
/// Only an explicit ScreenCaptureKit denial is reported as missing permission.
struct TBScreenCaptureAccess {
    private(set) var confirmed: Bool?

    func diagnosticPermission(preflight: Bool) -> Bool? {
        preflight ? true : confirmed
    }

    mutating func recordSuccess() { confirmed = true }

    mutating func recordFailure(_ error: Error) {
        if Self.isPermissionDenied(error) { confirmed = false }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamError.errorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }
}
