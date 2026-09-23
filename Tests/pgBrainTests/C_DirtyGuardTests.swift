import XCTest
@testable import pgBrain

final class C_DirtyGuardTests: XCTestCase {
    func testDecision() {
        XCTAssertEqual(DirtyGuard.decide(hasPendingChanges: false, isApplying: false), .proceed)
        XCTAssertEqual(DirtyGuard.decide(hasPendingChanges: true, isApplying: false), .confirm)
        XCTAssertEqual(DirtyGuard.decide(hasPendingChanges: true, isApplying: true), .block)
        XCTAssertEqual(DirtyGuard.decide(hasPendingChanges: false, isApplying: true), .block)
    }

    func testResolution() {
        XCTAssertEqual(DirtyGuard.resolve(.apply), .applyThenProceed)
        XCTAssertEqual(DirtyGuard.resolve(.discard), .discardThenProceed)
        XCTAssertEqual(DirtyGuard.resolve(.cancel), .stay)
    }

    func testProceedOnlyAfterACleanApply() {
        XCTAssertTrue(DirtyGuard.proceedAfterApply(succeeded: true, stillPending: false))
        XCTAssertFalse(DirtyGuard.proceedAfterApply(succeeded: false, stillPending: true), "failed apply keeps page + edits")
        XCTAssertFalse(DirtyGuard.proceedAfterApply(succeeded: true, stillPending: true), "edits staged during the apply")
    }

    /// Clicking from the WHERE field into the grid commits the field; with
    /// staged edits that must not reload.
    func testClauseCommitRules() {
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .focusLoss, changed: false, hasPendingChanges: true), .ignore)
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .enter, changed: false, hasPendingChanges: false), .ignore)
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .focusLoss, changed: true, hasPendingChanges: false), .reload)
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .enter, changed: true, hasPendingChanges: false), .reload)
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .focusLoss, changed: true, hasPendingChanges: true), .keepDraft)
        XCTAssertEqual(DirtyGuard.clauseCommit(trigger: .enter, changed: true, hasPendingChanges: true), .confirmReload)
    }
}
