import FieldContracts
// Port of __tests__/diagnostics.test.ts — diagnostic logs + report (§4f-g). The report must be
// copy-pasteable AND secret-free.
import XCTest

@testable import FieldDomain

final class DiagnosticsTests: XCTestCase {
    private let T0: Int64 = 1_750_000_000_000

    private func log(_ id: String, _ message: String, context: [String: JSONValue]? = nil) -> DiagnosticLog {
        DiagnosticLog(id: id, level: .info, message: message, context: context, createdAt: "2026-06-15T03:00:00.000Z")
    }

    func testAppendsAndReturnsTheMostRecentFirstCapped() throws {
        let store = VolatileDiagnosticLogStore()
        try store.record(log("a", "first"))
        try store.record(log("b", "second"))
        try store.record(log("c", "third"))
        XCTAssertEqual(try store.count(), 3)
        XCTAssertEqual(try store.recent(2).map(\.id), ["c", "b"])
    }

    private func baseInput(lastHubContactAtMs: Int64?, recentLogs: [DiagnosticLog] = []) -> DiagnosticReportInput {
        DiagnosticReportInput(
            appEnv: "dev",
            hubUrl: "http://192.168.1.149:8000",
            storageDurability: .durableEncrypted,
            lastHubContactAtMs: lastHubContactAtMs,
            offlinePolicyState: "offline-within-limit",
            counts: ["waiting-to-sync": 2, "needs-review": 1],
            recentLogs: recentLogs,
            generatedAtMs: T0
        )
    }

    func testRendersACopyPasteableReportWithEnvContactPolicyAndQueueCounts() {
        let report = buildDiagnosticReport(baseInput(lastHubContactAtMs: T0 - 5 * 60 * 60 * 1000))
        XCTAssertTrue(report.contains("hub env: dev"))
        XCTAssertTrue(report.contains("hub url: http://192.168.1.149:8000"))
        XCTAssertTrue(report.contains("local storage: durable-encrypted"))
        XCTAssertTrue(report.contains("offline policy: offline-within-limit"))
        XCTAssertTrue(report.contains("waiting-to-sync: 2"))
        XCTAssertTrue(report.contains("needs-review: 1"))
    }

    func testSaysNeverWhenThereHasBeenNoHubContact() {
        let report = buildDiagnosticReport(baseInput(lastHubContactAtMs: nil))
        XCTAssertTrue(report.contains("last hub contact: never"))
    }

    func testRedactsAnyCredentialLikeContextKeyTheReportCanNeverLeakAToken() {
        let entry = log("x", "auth refresh", context: ["authorization": "Bearer super-secret", "httpStatus": 401])
        let report = buildDiagnosticReport(baseInput(lastHubContactAtMs: T0, recentLogs: [entry]))
        XCTAssertFalse(report.contains("super-secret"))
        XCTAssertTrue(report.contains("[redacted]"))
        XCTAssertTrue(report.contains("401"))  // non-secret context survives
    }

    func testRecursivelyRedactsNestedSecretsBearerTextAndUrlQueries() {
        let entry = log(
            "x",
            "request https://hub.example/sync?access_token=query-secret failed with Bearer message-secret",
            context: [
                "request": .object([
                    "headers": .object(["authorization": .string("Bearer nested-secret")]),
                    "url": .string("https://hub.example/pull?cursor=private-cursor"),
                ])
            ]
        )
        let report = buildDiagnosticReport(
            baseInput(lastHubContactAtMs: T0, recentLogs: [entry])
        )

        for secret in ["query-secret", "message-secret", "nested-secret", "private-cursor"] {
            XCTAssertFalse(report.contains(secret))
        }
        XCTAssertTrue(report.contains("[redacted]"))
    }
}
