import Foundation
import FieldContracts
// Port of __tests__/real-hub-assignments.test.ts — real-Hub wire-contract regression. The fixture
// below is a VERBATIM `GET /api/v1/sync/assignments` response captured from a locally-running
// opshub Hub (`make up`, :8000) for an assigned Service Request (mirrors
// __tests__/fixtures/real-hub-assignments.json). It guards the three wire-breaks that used to
// empty the assignment list against the real Hub:
//   1. latest_server_version is a STRING (== snapshot_hash), not an integer.
//   2. job_type is an OBJECT { id, name }, not a bare string.
//   3. workflow_requirements is { clock_in_required, required_steps[] }, not the legacy require_*
//      booleans.
import XCTest

@testable import FieldDomain

private let REAL_HUB_ASSIGNMENTS_JSON = """
    [
      {
        "coordinates": {
          "primary": null,
          "wells": []
        },
        "customer": {
          "id": "cbaf53e3-a698-4209-bdc4-9aa8bae23975",
          "name": "Acme Energy, LLC"
        },
        "disposal_site": null,
        "geofence_hints": {
          "radius_m": 250,
          "required": false,
          "source": ""
        },
        "job_type": {
          "id": "11946f7f-49f7-4cce-b5f0-b2ea03d47dda",
          "name": "Vacuum Haul"
        },
        "latest_server_version": "98ed8db1d6fae30e3cd8b8135bb611669a6e6c3e9aa96df2956ee8e174d9321e",
        "lease": {
          "id": "c95016cc-2b8a-460d-aaa8-34935b463722",
          "name": "Northfield"
        },
        "material": {
          "id": "671a4325-cf18-41e4-a787-c4f9c00122d5",
          "name": "Produced Water"
        },
        "request_no": "2026-000001",
        "service_request_id": "2fa77824-e9c0-48d8-b707-c9482084cee9",
        "snapshot": {
          "workflow_requirements": {
            "clock_in_required": true,
            "required_steps": []
          }
        },
        "snapshot_hash": "98ed8db1d6fae30e3cd8b8135bb611669a6e6c3e9aa96df2956ee8e174d9321e",
        "status": "assigned",
        "vehicle": null,
        "wells": [
          {
            "api_number": null,
            "field_name": "",
            "id": "06f59e71-0ff0-4e3a-8b17-28472062f6c0",
            "lat": null,
            "lon": null,
            "well_no": "114H"
          }
        ],
        "workflow_requirements": {
          "clock_in_required": true,
          "required_steps": []
        }
      }
    ]
    """

final class RealHubAssignmentsTests: XCTestCase {
    private func loadFixture() throws -> [[String: Any]] {
        let data = REAL_HUB_ASSIGNMENTS_JSON.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [[String: Any]])
    }

    func testParsesTheVerbatimHubResponseWithoutThrowing() throws {
        let payload = try loadFixture()
        XCTAssertGreaterThan(payload.count, 0)
        XCTAssertNoThrow(try payload.map { try parseHubAssignmentEntry($0) })
    }

    func testReadsLatestServerVersionAsTheStringSnapshotHashNotAnInteger() throws {
        let entry = try loadFixture()[0]
        let parsed = try parseHubAssignmentEntry(entry)
        XCTAssertEqual(parsed.latestServerVersion, entry["snapshot_hash"] as? String)
    }

    func testReadsJobTypeAsAnObjectIdName() throws {
        let parsed = try parseHubAssignmentEntry(try loadFixture()[0])
        XCTAssertEqual(
            parsed.details?.jobType, AssignmentNamedRef(id: "11946f7f-49f7-4cce-b5f0-b2ea03d47dda", name: "Vacuum Haul")
        )
    }

    func testReadsWorkflowRequirementsAsClockInRequiredRequiredSteps() throws {
        let parsed = try parseHubAssignmentEntry(try loadFixture()[0])
        XCTAssertEqual(
            parsed.details?.workflowRequirements, WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        XCTAssertEqual(
            parseWorkflowRequirementsFromAssignments([parsed]),
            WorkflowRequirements(clockInRequired: true, requiredSteps: [])
        )
    }

    func testMapsTheRichMasterDataRefsTheDriverNeedsOnDevice() throws {
        let parsed = try parseHubAssignmentEntry(try loadFixture()[0])
        XCTAssertEqual(
            parsed.details?.customer,
            AssignmentNamedRef(id: "cbaf53e3-a698-4209-bdc4-9aa8bae23975", name: "Acme Energy, LLC"))
        XCTAssertEqual(parsed.details?.lease?.name, "Northfield")
        XCTAssertEqual(parsed.details?.material, "Produced Water")
    }

    func testLabelsWellsByWellNoSoTheDriverSeesTheWellNumberNotAUuid() throws {
        let parsed = try parseHubAssignmentEntry(try loadFixture()[0])
        XCTAssertEqual(
            parsed.details?.wells, [AssignmentWell(id: "06f59e71-0ff0-4e3a-8b17-28472062f6c0", name: "114H")])
    }

    func testLabelsTheVehicleByTruckNoWhenTheHubAssignsOneNotTheVehicleUuid() throws {
        let parsed = try parseHubAssignmentEntry(
            [
                "service_request_id": "sr-veh", "snapshot_hash": "h-veh",
                "vehicle": ["id": "veh-1", "truck_no": "Truck 12", "vehicle_type": "Vacuum", "capacity_bbl": 130]
                    as [String: Any],
            ] as [String: Any])
        XCTAssertEqual(parsed.details?.vehicle, AssignmentNamedRef(id: "veh-1", name: "Truck 12"))
    }

    func testCapturesRequestNoStatusAndGeofenceHintsDropsNullCoordinates() throws {
        let parsed = try parseHubAssignmentEntry(try loadFixture()[0])
        XCTAssertEqual(parsed.details?.requestNo, "2026-000001")
        XCTAssertEqual(parsed.details?.status, .assigned)
        XCTAssertEqual(parsed.details?.geofenceHints, AssignmentGeofenceHints(radiusM: 250, required: false))
        // This SR's wells have null lat/lon, so validation-only coordinates resolve to none.
        XCTAssertNil(parsed.details?.coordinates)
    }

    func testParsesPopulatedCoordinatesAsValidationOnlyPointsNotNavRoutingData() throws {
        let parsed = try parseHubAssignmentEntry(
            [
                "service_request_id": "sr-geo", "snapshot_hash": "h-geo",
                "coordinates": [
                    "primary": ["lat": 31.5, "lon": -102.1] as [String: Any],
                    "wells": [["well_id": "w-1", "lat": 31.5, "lon": -102.1] as [String: Any]],
                ] as [String: Any],
            ] as [String: Any])
        XCTAssertEqual(
            parsed.details?.coordinates,
            AssignmentCoordinates(
                primary: AssignmentGpsPoint(lat: 31.5, lon: -102.1),
                wells: [AssignmentWellCoordinate(lat: 31.5, lon: -102.1, wellId: "w-1")])
        )
    }
}
