import XCTest
@testable import SuperWorkspace

final class AIConnectionTests: XCTestCase {
    func testNormalizesTheEndpointForPiAndKeychain() throws {
        let scheme = "https"
        let base = try AIEndpoint(" \(scheme)://LOCALHOST:8443/v1/ ")
        let full = try AIEndpoint("\(scheme)://localhost:8443/v1/chat/completions")
        XCTAssertEqual(base.url, full.url)
        XCTAssertEqual(base.baseURL.path, "/v1")
        XCTAssertTrue(base.isLoopback)
        XCTAssertThrowsError(try AIEndpoint("\(scheme)://localhost/v1?secret=fixture"))
    }

    func testAllowsOnlyLoopbackHTTPAndRequiresRemoteCredentials() throws {
        let host = "api.invalid"
        let scheme = "http"
        XCTAssertThrowsError(try AIEndpoint("\(scheme)://\(host)/v1"))
        let local = try AIEndpoint("\(scheme)://localhost/v1")
        XCTAssertNoThrow(try AIConnection(endpoint: local, model: "fixture", key: ""))
        let remote = try AIEndpoint("\(scheme)s://\(host)/v1")
        XCTAssertThrowsError(try AIConnection(endpoint: remote, model: "fixture", key: ""))
        XCTAssertThrowsError(try AIConnection(endpoint: remote, model: "fixture", key: "line\nbreak"))
    }

    func testProviderPresetsProduceValidEndpoints() throws {
        XCTAssertFalse(AIProviderPreset.all.isEmpty)
        for preset in AIProviderPreset.all {
            let endpoint = try AIEndpoint(preset.baseURL)
            XCTAssertTrue(endpoint.url.path.hasSuffix("/chat/completions"), "Preset \(preset.id) should normalize to /chat/completions")
            XCTAssertFalse(preset.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if preset.id == "ollama" {
                XCTAssertTrue(endpoint.isLoopback)
                XCTAssertNoThrow(try AIConnection(endpoint: endpoint, model: preset.defaultModel, key: ""))
            } else {
                XCTAssertFalse(endpoint.isLoopback)
                XCTAssertEqual(endpoint.url.scheme, "https")
            }
        }
    }
}
