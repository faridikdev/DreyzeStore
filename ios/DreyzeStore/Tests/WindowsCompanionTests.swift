import Foundation
import XCTest
@testable import DreyzeStore

final class WindowsCompanionTests: XCTestCase {
    func testPairingPayloadRequiresPinnedHTTPSPrivateAddressAndShortLivedCodeShape() throws {
        let valid = #"{"version":1,"endpoint":"https://192.168.1.20:44218/api/v1","certificateSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","pairingCode":"ABCD1234EF56"}"#
        let payload = try WindowsCompanionPairingPayload.decode(valid)
        XCTAssertEqual(payload.endpoint.scheme, "https")
        XCTAssertEqual(payload.pairingCode, "ABCD1234EF56")

        let insecure = valid.replacingOccurrences(of: "https://192.168.1.20", with: "http://192.168.1.20")
        XCTAssertThrowsError(try WindowsCompanionPairingPayload.decode(insecure))
        let publicHost = valid.replacingOccurrences(of: "192.168.1.20", with: "8.8.8.8")
        XCTAssertThrowsError(try WindowsCompanionPairingPayload.decode(publicHost))
        let userInfo = valid.replacingOccurrences(of: "https://192.168.1.20", with: "https://attacker@192.168.1.20")
        XCTAssertThrowsError(try WindowsCompanionPairingPayload.decode(userInfo))
        let invalidCode = valid.replacingOccurrences(of: "ABCD1234EF56", with: "short")
        XCTAssertThrowsError(try WindowsCompanionPairingPayload.decode(invalidCode))
    }

    func testReceiptDecodesNestedSerdeStateAndInstalledInventoryConfirmation() throws {
        let json = #"{"requestId":"a182a71e-a2cf-4f8a-8a46-b6f63a2ab7ad","state":{"state":"installed","detail":{"app":{"bundleIdentifier":"com.example.reader","version":"2.0.1","build":"41"},"installedAt":"2026-09-28T10:00:00Z","signing":{"signedSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}"#
        let receipt = try JSONDecoder.companion.decode(CompanionInstallReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(receipt.state, "installed")
        XCTAssertEqual(receipt.requestID, "a182a71e-a2cf-4f8a-8a46-b6f63a2ab7ad")
        XCTAssertEqual(receipt.detail?.app?.bundleIdentifier, "com.example.reader")
        XCTAssertEqual(receipt.detail?.app?.version, "2.0.1")
        XCTAssertEqual(receipt.detail?.app?.build, "41")
        XCTAssertNotNil(receipt.detail?.installedAt)
    }

    func testReceiptDecodesNestedInstallationFailureWithoutSuccessFallback() throws {
        let json = #"{"requestId":"a182a71e-a2cf-4f8a-8a46-b6f63a2ab7ad","state":{"state":"failed","detail":{"code":"signing","message":"The profile is expired."}}}"#
        let receipt = try JSONDecoder.companion.decode(CompanionInstallReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(receipt.state, "failed")
        XCTAssertEqual(receipt.detail?.message, "The profile is expired.")
        XCTAssertNil(receipt.detail?.app)
    }

    func testWindowsCompanionBackendRequiresAnExplicitConfirmedInstallCapability() {
        let backend = WindowsCompanionInstallationBackend()
        XCTAssertTrue(backend.capabilities.contains(.confirmedInstall))
        XCTAssertTrue(backend.capabilities.contains(.inventory))
        XCTAssertTrue(backend.capabilities.contains(.uninstall))
        XCTAssertFalse(backend.capabilities.contains(.externalHandoff))
    }
}
