import Foundation
// Port of src/_generated.test.ts
import XCTest

@testable import FieldContracts

final class GeneratedTests: XCTestCase {
    private func loadManifest() throws -> [String: Any] {
        // Mirrors the TS test's `resolve(__dirname, "../../..")` — walk up from this file to the
        // repo root, then down into `contracts/triad-contract.json`.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GeneratedTests.swift -> FieldContractsTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> FieldKit/
            .deletingLastPathComponent()  // -> native/
            .deletingLastPathComponent()  // -> apps/
            .deletingLastPathComponent()  // -> repo root
        let manifestURL = repoRoot.appendingPathComponent("contracts/triad-contract.json")
        let data = try Data(contentsOf: manifestURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testVersionMatchesTheVendoredManifest() throws {
        let m = try loadManifest()
        XCTAssertEqual(CONTRACT_VERSION, m["version"] as? String)
    }

    func testOpTypesMatchTheManifestSorted() throws {
        let m = try loadManifest()
        let manifestTypes = ((m["sync_op_types"] as? [String]) ?? []).sorted()
        XCTAssertEqual(SYNC_OP_TYPES, manifestTypes)
    }
}
