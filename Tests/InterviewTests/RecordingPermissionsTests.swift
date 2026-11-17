import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import Interview

final class RecordingPermissionsTests: XCTestCase {
    func testAuthorizedMicrophoneDoesNotAskAgain() async throws {
        var requests = 0
        for _ in 0..<3 {
            try await RecordingPermissions.ensureMicrophone(status: .authorized) { requests += 1; return false }
        }
        XCTAssertEqual(requests, 0)
    }
    func testUndeterminedRequestsAndDeniedDoesNotLoop() async throws {
        var requests = 0
        try await RecordingPermissions.ensureMicrophone(status: .notDetermined) { requests += 1; return true }
        XCTAssertEqual(requests, 1)
        for status in [AVAuthorizationStatus.denied, .restricted] {
            do {
                try await RecordingPermissions.ensureMicrophone(status: status) { requests += 1; return true }
                XCTFail("Denied access must not be treated as authorized")
            } catch { }
        }
        XCTAssertEqual(requests, 1)
    }
    func testCaptureErrorOnlyExplainsAuthorizationFailures() {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(RecordingPermissions.explainCaptureError(denied).localizedDescription.contains("開き直してください"))
        let other = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)
        XCTAssertEqual(RecordingPermissions.explainCaptureError(other) as NSError, other)
    }
}
