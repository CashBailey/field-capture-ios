// Port of test/sync.test.ts
import XCTest

@testable import FieldContracts

private typealias Payload = [String: JSONValue]

final class SyncTests: XCTestCase {
    // ---- helpers ----

    private func env(
        opId: String,
        localSeq: Int,
        kind: OperationKind = .command,
        type: String = "sr.edit",
        dependsOn: [String] = [],
        precondition: VersionPrecondition? = nil
    ) throws -> OperationEnvelope<Payload> {
        OperationEnvelope(
            opId: opId,
            kind: kind,
            type: type,
            idempotencyKey: try buildIdempotencyKey("devA", localSeq, opId),
            localSeq: localSeq,
            dependsOn: dependsOn,
            precondition: precondition,
            payload: [:]
        )
    }

    private func item(
        _ envelope: OperationEnvelope<Payload>,
        _ state: OutboxItemState = .pending,
        committedToken: ChangeToken? = nil,
        rejectionCode: String? = nil
    ) -> OutboxItem<Payload> {
        OutboxItem(
            envelope: envelope, state: state, retryCount: 0, committedToken: committedToken,
            rejectionCode: rejectionCode)
    }

    private let TOKEN = ChangeToken(authorityEpoch: 1, commitSeq: 42)

    // ---- envelope consistency ----

    func testAcceptsACoherentCommandEnvelope() throws {
        XCTAssertNoThrow(try assertEnvelopeConsistent(try env(opId: "op1", localSeq: 1)))
    }

    func testRejectsALocalSeqThatDisagreesWithTheIdempotencyKey() throws {
        var e = try env(opId: "op1", localSeq: 1)
        e.localSeq = 2
        XCTAssertThrowsError(try assertEnvelopeConsistent(e)) { error in
            XCTAssertTrue(error is OutboxError)
        }
    }

    func testRejectsASelfDependencyAndDuplicateDependsOn() throws {
        XCTAssertThrowsError(try assertEnvelopeConsistent(try env(opId: "op1", localSeq: 1, dependsOn: ["op1"]))) {
            error in
            XCTAssertTrue("\(error)".contains("depends on itself"))
        }
        XCTAssertThrowsError(try assertEnvelopeConsistent(try env(opId: "op1", localSeq: 1, dependsOn: ["a", "a"]))) {
            error in
            XCTAssertTrue("\(error)".contains("duplicate dependsOn"))
        }
    }

    func testRejectsAnImmutableEventThatCarriesAPrecondition() throws {
        let e = try env(opId: "op1", localSeq: 1, kind: .event, precondition: VersionPrecondition(baseVersion: 3))
        XCTAssertThrowsError(try assertEnvelopeConsistent(e)) { error in
            XCTAssertTrue("\(error)".contains("append-only"))
        }
    }

    func testRejectsANegativeOrNonIntegerLocalSeq() throws {
        var e = try env(opId: "op1", localSeq: 0)
        e.localSeq = -1
        XCTAssertThrowsError(try assertEnvelopeConsistent(e)) { error in
            XCTAssertTrue(error is OutboxError)
        }
    }

    // ---- outbox state machine ----

    func testPermitsOnlyTheDocumentedTransitions() {
        XCTAssertTrue(canTransition(.pending, .inFlight))
        XCTAssertTrue(canTransition(.inFlight, .accepted))
        XCTAssertTrue(canTransition(.inFlight, .pending))
        XCTAssertFalse(canTransition(.pending, .accepted))  // must dispatch first
        XCTAssertFalse(canTransition(.accepted, .pending))  // terminal
    }

    func testMarkInFlightThenApplyCommandResultAcceptedRecordsTheToken() throws {
        let sent = try markInFlight(item(try env(opId: "op1", localSeq: 1)))
        XCTAssertEqual(sent.state, .inFlight)
        let result: CommandResult<Payload> = .accepted(opId: "op1", token: TOKEN)
        let done = try applyCommandResult(sent, result)
        XCTAssertEqual(done.state, .accepted)
        XCTAssertEqual(done.committedToken, TOKEN)
    }

    func testAcceptCannotSkipInFlight() throws {
        let pending = item(try env(opId: "op1", localSeq: 1))
        let result: CommandResult<Payload> = .accepted(opId: "op1", token: TOKEN)
        XCTAssertThrowsError(try applyCommandResult(pending, result)) { error in
            XCTAssertTrue("\(error)".contains("illegal outbox transition"))
        }
    }

    func testRejectedAndNeedsReviewFoldInTheirReasons() throws {
        let sent = try markInFlight(item(try env(opId: "op1", localSeq: 1)))
        let rejected = try applyCommandResult(sent, .rejected(opId: "op1", rejectionCode: "stale_version"))
        XCTAssertEqual(rejected.state, .rejected)
        XCTAssertEqual(rejected.rejectionCode, "stale_version")
        let review = try applyCommandResult(
            sent, .needsReview(opId: "op1", reviewReason: "competing-work-start-evidence"))
        XCTAssertEqual(review.state, .needsReview)
    }

    func testMarkForRetryReturnsAnItemToPendingAndBumpsRetryCount() throws {
        let sent = try markInFlight(item(try env(opId: "op1", localSeq: 1)))
        let retried = try markForRetry(sent)
        XCTAssertEqual(retried.state, .pending)
        XCTAssertEqual(retried.retryCount, 1)
        XCTAssertThrowsError(try markForRetry(item(try env(opId: "op2", localSeq: 2))))  // pending->pending illegal
    }

    func testRejectsACommandResultWhoseOpIdDoesNotMatchTheItem() throws {
        let sent = try markInFlight(item(try env(opId: "op1", localSeq: 1)))
        XCTAssertThrowsError(try applyCommandResult(sent, .accepted(opId: "other", token: TOKEN))) { error in
            XCTAssertTrue("\(error)".contains("does not match"))
        }
    }

    func testDoesNotMutateItsInput() throws {
        let original = item(try env(opId: "op1", localSeq: 1))
        _ = try markInFlight(original)
        XCTAssertEqual(original.state, .pending)
    }

    func testApplyCommandResultThrowsLoudlyOnAnUnknownOutcome() {
        // ponytail: not portable — `CommandResult` is a real Swift enum, so an "unknown outcome"
        // case cannot be constructed; the exhaustive switch in `applyCommandResult` makes this
        // unreachable at compile time. See the doc comment in Sync/Outbox.swift.
    }

    // ---- dispatch planning ----

    func testReturnsDependencyFreePendingItemsInLocalSeqOrder() throws {
        let plan = try planDispatch([
            item(try env(opId: "c", localSeq: 3)),
            item(try env(opId: "a", localSeq: 1)),
            item(try env(opId: "b", localSeq: 2)),
        ])
        XCTAssertEqual(plan.ready.map(\.envelope.opId), ["a", "b", "c"])
        XCTAssertEqual(plan.waiting.count, 0)
        XCTAssertEqual(plan.blocked.count, 0)
    }

    func testHoldsADependentUntilItsParentIsAccepted() throws {
        let parentPending = [
            item(try env(opId: "p", localSeq: 1)),
            item(try env(opId: "child", localSeq: 2, dependsOn: ["p"])),
        ]
        var plan = try planDispatch(parentPending)
        XCTAssertEqual(plan.ready.map(\.envelope.opId), ["p"])
        XCTAssertEqual(plan.waiting.map(\.envelope.opId), ["child"])

        let parentAccepted = [
            item(try env(opId: "p", localSeq: 1), .accepted, committedToken: TOKEN),
            item(try env(opId: "child", localSeq: 2, dependsOn: ["p"])),
        ]
        plan = try planDispatch(parentAccepted)
        XCTAssertEqual(plan.ready.map(\.envelope.opId), ["child"])
    }

    func testTreatsADependencyInCommittedOpIdsAsSatisfied() throws {
        let plan = try planDispatch(
            [item(try env(opId: "child", localSeq: 2, dependsOn: ["gone"]))],
            committedOpIds: ["gone"]
        )
        XCTAssertEqual(plan.ready.map(\.envelope.opId), ["child"])
    }

    func testBlocksOnADeadDependency() throws {
        let rejParent = try planDispatch([
            item(try env(opId: "p", localSeq: 1), .rejected, rejectionCode: "stale_version"),
            item(try env(opId: "child", localSeq: 2, dependsOn: ["p"])),
        ])
        XCTAssertEqual(rejParent.blocked.count, 1)
        XCTAssertEqual(rejParent.blocked[0].reason, .deadDependency)
        XCTAssertEqual(rejParent.blocked[0].deps, ["p"])

        let absent = try planDispatch([item(try env(opId: "child", localSeq: 2, dependsOn: ["ghost"]))])
        XCTAssertEqual(absent.blocked[0].reason, .deadDependency)
        XCTAssertEqual(absent.blocked[0].deps, ["ghost"])
    }

    func testBlocksEveryMemberOfADependencyCycle() throws {
        let plan = try planDispatch([
            item(try env(opId: "a", localSeq: 1, dependsOn: ["b"])),
            item(try env(opId: "b", localSeq: 2, dependsOn: ["a"])),
        ])
        XCTAssertEqual(plan.ready.count, 0)
        XCTAssertEqual(plan.waiting.count, 0)
        XCTAssertEqual(plan.blocked.map(\.reason), [.dependencyCycle, .dependencyCycle])
    }

    func testLetsAPendingItemBehindAnInFlightPartnerWait() throws {
        let plan = try planDispatch([
            item(try env(opId: "a", localSeq: 1, dependsOn: ["b"]), .inFlight),
            item(try env(opId: "b", localSeq: 2, dependsOn: ["a"])),
        ])
        XCTAssertEqual(plan.blocked.count, 0)
        XCTAssertEqual(plan.waiting.map(\.envelope.opId), ["b"])
    }

    func testReportsBothCycleMembersAndDeadParentsInABlockedCyclesDeps() throws {
        let plan = try planDispatch([
            item(try env(opId: "a", localSeq: 1, dependsOn: ["b", "ghost"])),
            item(try env(opId: "b", localSeq: 2, dependsOn: ["a"])),
        ])
        let a = plan.blocked.first { $0.item.envelope.opId == "a" }
        XCTAssertEqual(a?.reason, .dependencyCycle)
        XCTAssertEqual(a?.deps.sorted(), ["b", "ghost"])
    }

    func testThrowsOnADuplicateOpId() {
        XCTAssertThrowsError(
            try planDispatch([item(try env(opId: "dup", localSeq: 1)), item(try env(opId: "dup", localSeq: 2))])
        ) { error in
            XCTAssertTrue("\(error)".contains("duplicate opId"))
        }
    }

    func testCommittedTokensCollectsAcceptedItemsTokens() throws {
        let tokens = committedTokens([
            item(try env(opId: "a", localSeq: 1), .accepted, committedToken: TOKEN),
            item(try env(opId: "b", localSeq: 2)),
        ])
        XCTAssertEqual(tokens, [TOKEN])
    }

    // ---- change token frontier ----

    func testComparesFreshnessAndPicksTheMax() {
        let older = ChangeToken(authorityEpoch: 1, commitSeq: 10)
        let newer = ChangeToken(authorityEpoch: 1, commitSeq: 11)
        XCTAssertTrue(isTokenNewer(newer, older))
        XCTAssertFalse(isTokenNewer(older, newer))
        XCTAssertEqual(maxToken(older, newer), newer)
    }

    func testAdvancesWithinAnEpochAndIsANoOpOnAnEqualToken() throws {
        XCTAssertEqual(
            try advanceFrontier(
                ChangeToken(authorityEpoch: 1, commitSeq: 10), ChangeToken(authorityEpoch: 1, commitSeq: 11)),
            ChangeToken(authorityEpoch: 1, commitSeq: 11)
        )
        XCTAssertEqual(
            try advanceFrontier(
                ChangeToken(authorityEpoch: 1, commitSeq: 11), ChangeToken(authorityEpoch: 1, commitSeq: 11)),
            ChangeToken(authorityEpoch: 1, commitSeq: 11)
        )
    }

    func testAcceptsAnEpochIncrementEvenWhenCommitSeqRestartsLower() throws {
        XCTAssertEqual(
            try advanceFrontier(
                ChangeToken(authorityEpoch: 1, commitSeq: 9999), ChangeToken(authorityEpoch: 2, commitSeq: 1)),
            ChangeToken(authorityEpoch: 2, commitSeq: 1)
        )
    }

    func testThrowsOnACommitSeqRegressionWithinAnEpoch() {
        XCTAssertThrowsError(
            try advanceFrontier(
                ChangeToken(authorityEpoch: 1, commitSeq: 11), ChangeToken(authorityEpoch: 1, commitSeq: 10))
        ) { error in
            XCTAssertTrue(error is ChangeTokenError)
        }
    }

    func testThrowsOnAnEpochRegression() {
        XCTAssertThrowsError(
            try advanceFrontier(
                ChangeToken(authorityEpoch: 2, commitSeq: 1), ChangeToken(authorityEpoch: 1, commitSeq: 9999))
        ) { error in
            XCTAssertTrue(error is ChangeTokenError)
        }
    }

    func testThrowsOnANaNOrNonIntegerTokenInsteadOfSilentlyPoisoningTheFrontier() {
        // ponytail: not portable — `ChangeToken`'s fields are Swift `Int` (always integral), so
        // the TS test's `commitSeq: NaN` / `authorityEpoch: 1.5` inputs are uncompilable here.
        // Swift's type system already rules out the corruption this TS guard defends against.
        // See the doc comment on `advanceFrontier` in Sync/ChangeToken.swift.
    }

    // ---- two-phase attachment ----

    private func blob(
        blobId: String = "b1",
        sha256: String = "abc",
        byteLength: Int = 100,
        state: BlobLifecycleState = .localOnly,
        uploadConfirmed: Bool = false,
        linkConfirmed: Bool = false
    ) -> BlobRecord {
        BlobRecord(
            blobId: blobId, sha256: sha256, byteLength: byteLength, state: state,
            uploadConfirmed: uploadConfirmed, linkConfirmed: linkConfirmed
        )
    }

    func testIsPurgeableOnlyWhenLinkedWithBothConfirmations() {
        XCTAssertFalse(isBlobPurgeable(blob()))
        XCTAssertFalse(isBlobPurgeable(blob(state: .uploaded, uploadConfirmed: true)))
        XCTAssertTrue(isBlobPurgeable(blob(state: .linked, uploadConfirmed: true, linkConfirmed: true)))
        // state says linked but a confirmation is missing -> still not purgeable (defensive triple-check)
        XCTAssertFalse(isBlobPurgeable(blob(state: .linked, uploadConfirmed: true)))
    }

    func testWalksLocalOnlyToUploadingToUploadedToLinkedAndBecomesPurgeable() throws {
        var b = blob()
        b = try advanceBlob(b, .uploadStarted)
        XCTAssertEqual(b.state, .uploading)
        b = try advanceBlob(b, .uploadConfirmed)
        XCTAssertEqual(b.state, .uploaded)
        XCTAssertTrue(b.uploadConfirmed)
        XCTAssertFalse(b.linkConfirmed)
        XCTAssertFalse(isBlobPurgeable(b))
        b = try advanceBlob(b, .linkConfirmed)
        XCTAssertEqual(b.state, .linked)
        XCTAssertTrue(b.uploadConfirmed)
        XCTAssertTrue(b.linkConfirmed)
        XCTAssertTrue(isBlobPurgeable(b))
    }

    func testShortCircuitsToUploadedOnADedupeHit() throws {
        let b = try advanceBlob(blob(), .alreadyPresent)
        XCTAssertEqual(b.state, .uploaded)
        XCTAssertTrue(b.uploadConfirmed)
    }

    func testCanExpireMidUploadAndResumeFromALocalCopy() throws {
        var b = try advanceBlob(blob(), .uploadStarted)
        b = try advanceBlob(b, .uploadExpired)
        XCTAssertEqual(b.state, .uploadExpired)
        b = try advanceBlob(b, .uploadStarted)
        XCTAssertEqual(b.state, .uploading)
    }

    func testRejectsAnIllegalTransition() {
        XCTAssertThrowsError(try advanceBlob(blob(), .linkConfirmed)) { error in
            XCTAssertTrue(error is AttachmentError)  // can't link before upload
        }
        XCTAssertThrowsError(try advanceBlob(blob(state: .linked), .uploadStarted)) { error in
            XCTAssertTrue(error is AttachmentError)  // terminal
        }
    }

    func testAssertLinkAllowedGatesTheLinkOnAConfirmedUpload() {
        XCTAssertThrowsError(try assertLinkAllowed(blob())) { error in
            XCTAssertTrue("\(error)".contains("before its upload is confirmed"))
        }
        XCTAssertNoThrow(try assertLinkAllowed(blob(state: .uploaded, uploadConfirmed: true)))
    }

    func testPurgeableBlobsFiltersToFullySyncedBlobsOnly() {
        let ready = blob(blobId: "ok", state: .linked, uploadConfirmed: true, linkConfirmed: true)
        let notReady = blob(blobId: "no", state: .uploaded, uploadConfirmed: true)
        XCTAssertEqual(purgeableBlobs([ready, notReady]).map(\.blobId), ["ok"])
    }

    // ---- conflict resolution mapping ----

    func testMapsAcceptedToCommitWithTheToken() {
        let result: CommandResult<Payload> = .accepted(opId: "op1", token: TOKEN)
        XCTAssertEqual(localActionFor(result), .commit(token: TOKEN))
    }

    func testMapsRejectedToMarkConflictedAndAlwaysPullsAFreshSnapshot() {
        let result: CommandResult<Payload> = .rejected(opId: "op1", rejectionCode: "locked_sr")
        XCTAssertEqual(localActionFor(result), .markConflicted(rejectionCode: "locked_sr", pullSnapshot: true))
    }

    func testMapsNeedsReviewToPreserveEvidenceAndFreeze() {
        let result: CommandResult<Payload> = .needsReview(opId: "op1", reviewReason: "stale-finalization")
        XCTAssertEqual(
            localActionFor(result), .preserveEvidenceAndFlag(reviewReason: "stale-finalization", freeze: true))
    }

    func testRecognizesKnownRejectionCodesAndDocumentedReviewTriggers() {
        XCTAssertTrue(isRejectionCode("stale_version"))
        XCTAssertFalse(isRejectionCode("nonsense"))
        XCTAssertTrue(REVIEW_TRIGGERS.contains("offline-work-start-after-reassignment"))
    }

    func testThrowsLoudlyOnAnUnknownOutcomeInsteadOfReturningUndefined() {
        // ponytail: not portable — `CommandResult` is a real Swift enum, so an "unknown outcome"
        // case cannot be constructed; the exhaustive switch in `localActionFor` makes this
        // unreachable at compile time. See the doc comment in Sync/Conflict.swift.
    }
}
