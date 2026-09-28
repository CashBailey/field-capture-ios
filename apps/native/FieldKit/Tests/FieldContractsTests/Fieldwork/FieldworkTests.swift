// Port of test/fieldwork.test.ts
import XCTest

@testable import FieldContracts

final class FieldworkTests: XCTestCase {
    private func makeSr(
        srId: String = "sr-1",
        version: Int = 1,
        ownerRef: String = "emp-1",
        assistantRefs: [String] = [],
        lockState: SrLockState = .unlocked,
        workStartedAt: String? = nil,
        lockedByEventId: String? = nil
    ) -> ServiceRequest {
        ServiceRequest(
            srId: srId, version: version, ownerRef: ownerRef, assistantRefs: assistantRefs,
            lockState: lockState, workStartedAt: workStartedAt, lockedByEventId: lockedByEventId
        )
    }

    // ---- SR lock invariant ----

    func testIsEditableWhileUnlockedNotAfterLock() throws {
        let open = makeSr()
        XCTAssertTrue(canEditSr(open))

        let event = WorkStartEvent(
            eventId: "ev-1", srId: "sr-1", kind: .jhajsaSigned, actorRef: "emp-1",
            occurredAt: "2026-06-07T12:00:00.000Z"
        )
        let locked = try applyWorkStart(open, event)
        XCTAssertEqual(locked.lockState, .locked)
        XCTAssertEqual(locked.workStartedAt, event.occurredAt)
        XCTAssertEqual(locked.lockedByEventId, "ev-1")
        XCTAssertFalse(canEditSr(locked))
    }

    func testFirstWorkStartEventLocksLaterEventsDoNotRelock() throws {
        let first = try applyWorkStart(
            makeSr(),
            WorkStartEvent(eventId: "ev-1", srId: "sr-1", kind: .arrived, actorRef: "emp-1", occurredAt: "t1")
        )
        let second = try applyWorkStart(
            first,
            WorkStartEvent(
                eventId: "ev-2", srId: "sr-1", kind: .fieldTicketStarted, actorRef: "emp-2", occurredAt: "t2")
        )
        XCTAssertEqual(second.lockedByEventId, "ev-1")
        XCTAssertEqual(second.workStartedAt, "t1")
    }

    func testDoesNotMutateTheInputSr() throws {
        let open = makeSr()
        _ = try applyWorkStart(
            open, WorkStartEvent(eventId: "ev-1", srId: "sr-1", kind: .arrived, actorRef: "e", occurredAt: "t"))
        XCTAssertEqual(open.lockState, .unlocked)
    }

    func testRejectsAnEventForADifferentSr() {
        XCTAssertThrowsError(
            try applyWorkStart(
                makeSr(), WorkStartEvent(eventId: "ev", srId: "other", kind: .arrived, actorRef: "e", occurredAt: "t"))
        ) { error in
            XCTAssertTrue(error is FieldworkRuleError)
        }
    }

    // ---- JHA/JSA signatures are append-only ----

    func testAppendsMultipleSigners() throws {
        let a = JhaJsaSignature(signatureId: "s1", srId: "sr-1", signerRef: "e1", signatureBlobId: "b1", signedAt: "t1")
        let b = JhaJsaSignature(signatureId: "s2", srId: "sr-1", signerRef: "e2", signatureBlobId: "b2", signedAt: "t2")
        let list = try appendSignature(try appendSignature([], a), b)
        XCTAssertEqual(list.map(\.signatureId), ["s1", "s2"])
    }

    func testRefusesToOverwriteAnExistingSignatureId() {
        let a = JhaJsaSignature(signatureId: "s1", srId: "sr-1", signerRef: "e1", signatureBlobId: "b1", signedAt: "t1")
        var hacked = a
        hacked.signerRef = "hacker"
        XCTAssertThrowsError(try appendSignature([a], hacked)) { error in
            XCTAssertTrue("\(error)".contains("append-only"))
        }
    }

    // ---- field ticket draft/submit immutability ----

    private func draftTicket() -> FieldTicket {
        FieldTicket(
            fieldTicketId: "ft-1", srId: "sr-1", version: 1, state: .draft, createdAt: "t0",
            submittedAt: nil, fields: ["volume": 10]
        )
    }

    func testEditsBumpVersionWhileDraft() throws {
        let edited = try editDraftTicket(draftTicket(), ["volume": 20, "well": "W-7"])
        XCTAssertEqual(edited.version, 2)
        XCTAssertEqual(edited.fields, ["volume": 20, "well": "W-7"])
    }

    func testSubmittedTicketsAreImmutableExceptViaAmendment() throws {
        let submitted = try submitTicket(draftTicket(), "t1")
        XCTAssertEqual(submitted.state, .submitted)
        XCTAssertThrowsError(try editDraftTicket(submitted, ["volume": 99])) { error in
            XCTAssertTrue("\(error)".contains("immutable"))
        }
        XCTAssertThrowsError(try submitTicket(submitted, "t2")) { error in
            XCTAssertTrue("\(error)".contains("already"))
        }
    }

    // ---- ticket amendment (correction workflow) ----

    private func submittedTicket() -> FieldTicket {
        FieldTicket(
            fieldTicketId: "ft-1", srId: "sr-1", version: 2, state: .submitted, createdAt: "t0",
            submittedAt: "t1", fields: ["volume": 20]
        )
    }

    func testAmendsASubmittedTicketBumpsVersionMergesFields() throws {
        let amended = try amendTicket(submittedTicket(), ["volume": 25], "t2")
        XCTAssertEqual(amended.state, .amended)
        XCTAssertEqual(amended.version, 3)
        XCTAssertEqual(amended.fields, ["volume": 25])
    }

    func testAllowsReamendmentOfAnAlreadyAmendedTicket() throws {
        let once = try amendTicket(submittedTicket(), ["a": 1], "t2")
        let twice = try amendTicket(once, ["b": 2], "t3")
        XCTAssertEqual(twice.state, .amended)
        XCTAssertEqual(twice.version, 4)
    }

    func testRefusesToAmendADraft() {
        var draft = submittedTicket()
        draft.state = .draft
        draft.submittedAt = nil
        XCTAssertThrowsError(try amendTicket(draft, [:], "t2")) { error in
            XCTAssertTrue("\(error)".contains("only submitted tickets"))
        }
    }

    // ---- SR assignment + authorization ----

    func testAuthorizesTheOwnerAndAssistantsRejectsOthers() {
        let s = makeSr(ownerRef: "owner", assistantRefs: ["asst"])
        XCTAssertTrue(isActorAuthorized(s, "owner"))
        XCTAssertTrue(isActorAuthorized(s, "asst"))
        XCTAssertFalse(isActorAuthorized(s, "stranger"))
        XCTAssertThrowsError(try assertActorAuthorized(s, "stranger")) { error in
            XCTAssertTrue(error is FieldworkRuleError)
        }
    }

    func testReassignsOwnerSetsAssistantsOnlyWhileUnlocked() throws {
        let open = makeSr(version: 1)
        let reassigned = try reassignOwner(open, "owner2")
        XCTAssertEqual(reassigned.ownerRef, "owner2")
        XCTAssertEqual(reassigned.version, 2)
        let assisted = try setAssistants(open, ["a", "b"])
        XCTAssertEqual(assisted.assistantRefs, ["a", "b"])
        XCTAssertEqual(assisted.version, 2)

        let locked = makeSr(lockState: .locked)
        XCTAssertThrowsError(try reassignOwner(locked, "x")) { error in
            XCTAssertTrue("\(error)".contains("locked"))
        }
        XCTAssertThrowsError(try setAssistants(locked, ["x"])) { error in
            XCTAssertTrue("\(error)".contains("locked"))
        }
    }

    // ---- resolveWorkStart escalation (ADR 004 / report 03) ----

    private func workStartEvent() -> WorkStartEvent {
        WorkStartEvent(eventId: "ev-1", srId: "sr-1", kind: .arrived, actorRef: "emp-1", occurredAt: "t1")
    }

    func testLocksWhenAnUnlockedSrGetsAWorkStartFromAnAuthorizedActor() throws {
        let out = try resolveWorkStart(makeSr(), workStartEvent(), ["emp-1"])
        guard case .locked(let sr) = out else { return XCTFail("expected .locked") }
        XCTAssertEqual(sr.lockState, .locked)
    }

    func testTreatsAWorkStartOnAnAlreadyLockedSrAsEvidenceOnly() throws {
        let out = try resolveWorkStart(
            makeSr(lockState: .locked, lockedByEventId: "ev-0"), workStartEvent(), ["emp-1"]
        )
        guard case .evidenceOnly = out else { return XCTFail("expected .evidenceOnly") }
    }

    func testEscalatesToNeedsReviewWhenActorNoLongerAuthorized() throws {
        let out = try resolveWorkStart(
            makeSr(ownerRef: "newOwner", assistantRefs: []), workStartEvent(), ["newOwner"]
        )
        guard case .needsReview(let sr, let trigger) = out else { return XCTFail("expected .needsReview") }
        XCTAssertEqual(trigger, .offlineWorkStartAfterReassignment)
        XCTAssertEqual(sr.lockState, .unlocked)  // the phone never retroactively wins authority
    }

    func testResolveWorkStartRejectsAnEventForADifferentSr() {
        var event = workStartEvent()
        event.srId = "other"
        XCTAssertThrowsError(try resolveWorkStart(makeSr(), event, ["emp-1"])) { error in
            XCTAssertTrue(error is FieldworkRuleError)
        }
    }

    // ---- photo attachments are append-only + purge-gated ----

    private func makeAttachment(blobId: String = "b1", hubConfirmed: Bool = false) -> PhotoAttachment {
        PhotoAttachment(
            attachmentId: "att-1", blobId: blobId, sha256: "abc", kind: .fieldTicketPhoto,
            parentType: .fieldTicket, parentId: "ft-1", capturedAt: "t1", hubConfirmed: hubConfirmed
        )
    }

    func testAppendsDistinctAttachmentsRefusesADuplicateAttachmentId() throws {
        let list = try appendAttachment([], makeAttachment())
        XCTAssertEqual(list.count, 1)
        XCTAssertThrowsError(try appendAttachment(list, makeAttachment(blobId: "other"))) { error in
            XCTAssertTrue("\(error)".contains("append-only"))
        }
    }

    func testIsPurgeableOnlyOnceHubConfirmsUploadAndLink() {
        XCTAssertFalse(canPurgeAttachment(makeAttachment()))
        XCTAssertTrue(canPurgeAttachment(makeAttachment(hubConfirmed: true)))
    }
}
