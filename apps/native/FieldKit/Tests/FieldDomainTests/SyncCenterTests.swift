import FieldContracts
// Port of __tests__/sync-center.test.ts — pure Sync Center rollup (spec 7.15): raw
// outbox/draft/blob state → worker-facing buckets.
import XCTest

@testable import FieldDomain

final class SyncCenterTests: XCTestCase {
    private func ev(_ state: OutboxItemState, _ lastRejectionCode: String? = nil) -> SyncCenterEvidence {
        SyncCenterEvidence(state: state, lastRejectionCode: lastRejectionCode)
    }

    func testAnEmptyWorldHasNoOutstandingWork() {
        let s = summarizeSyncCenter(SyncCenterInput(draftCount: 0, evidence: []))
        XCTAssertEqual(s.total, 0)
        XCTAssertFalse(s.hasOutstanding)
        XCTAssertEqual(s.counts[.waitingToSync], 0)
    }

    func testBucketsEachOutboxStateIntoTheRightWorkerFacingCategory() {
        let s = summarizeSyncCenter(
            SyncCenterInput(
                draftCount: 2,
                evidence: [
                    ev(.pending),  // waiting-to-sync
                    ev(.inFlight),  // waiting-to-sync
                    ev(.pending, "not_clocked_in"),  // waiting-on-you (a 403/409 block)
                    ev(.accepted),
                    ev(.needsReview),
                    ev(.rejected),
                ],
                blobs: [SyncCenterBlob(linkConfirmed: false), SyncCenterBlob(linkConfirmed: true)]
            ))
        XCTAssertEqual(
            s.counts,
            [
                .savedOnPhone: 2,
                .waitingToSync: 3,  // 2 evidence + 1 unlinked blob
                .waitingOnYou: 1,
                .acceptedByHub: 2,  // 1 evidence + 1 linked blob
                .needsReview: 1,
                .rejectedByHub: 1,
            ])
        XCTAssertEqual(s.total, 10)
        XCTAssertTrue(s.hasOutstanding)
    }

    func testOnlyHubAcceptedWorkCountsAsAcceptedABlockedPendingIsNeverSynced() {
        let s = summarizeSyncCenter(SyncCenterInput(draftCount: 0, evidence: [ev(.pending, "in_progress")]))
        XCTAssertEqual(s.counts[.acceptedByHub], 0)
        XCTAssertEqual(s.counts[.waitingOnYou], 1)
        XCTAssertEqual(s.counts[.waitingToSync], 0)
    }

    func testAcceptedOnlyWorkIsDurableOnHubWithNothingOutstanding() {
        let s = summarizeSyncCenter(SyncCenterInput(draftCount: 0, evidence: [ev(.accepted), ev(.accepted)]))
        XCTAssertFalse(s.hasOutstanding)
        XCTAssertEqual(s.counts[.acceptedByHub], 2)
    }

    func testExposesAPlainLanguageLabelAndAStableDisplayOrderForEveryCategory() {
        XCTAssertEqual(SYNC_CENTER_ORDER.count, 6)
        for category in SYNC_CENTER_ORDER {
            XCTAssertNotNil(SYNC_CENTER_LABELS[category])
        }
        XCTAssertEqual(SYNC_CENTER_LABELS[.needsReview], "Needs office review")
    }
}
