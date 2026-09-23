import XCTest
@testable import pgBrain

/// AuthenticationOk after a started SCRAM exchange is only accepted once the
/// server signature in SASLFinal verified.
final class F2_ScramStateTests: XCTestCase {
    private let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private let goodFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    private func client() -> PGScramSHA256 {
        PGScramSHA256(password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO", username: "user")
    }

    func testNoScramAcceptsOk() {
        XCTAssertTrue(PGWireIO.acceptsAuthenticationOk(scram: nil))
    }

    func testOkWithoutSASLFinalIsRejected() throws {
        var scram = client()
        XCTAssertFalse(PGWireIO.acceptsAuthenticationOk(scram: scram))
        _ = try scram.clientFinalMessage(serverFirst: serverFirst)
        XCTAssertFalse(PGWireIO.acceptsAuthenticationOk(scram: scram))
    }

    func testOkAfterBadSignatureIsRejected() throws {
        var scram = client()
        _ = try scram.clientFinalMessage(serverFirst: serverFirst)
        XCTAssertFalse(scram.verify(serverFinal: "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
        XCTAssertFalse(PGWireIO.acceptsAuthenticationOk(scram: scram))
    }

    func testOkAfterVerifiedFinalIsAccepted() throws {
        var scram = client()
        _ = try scram.clientFinalMessage(serverFirst: serverFirst)
        XCTAssertTrue(scram.verify(serverFinal: goodFinal))
        XCTAssertTrue(PGWireIO.acceptsAuthenticationOk(scram: scram))
    }

    func testVerifyBeforeClientFinalFails() {
        var scram = client()
        XCTAssertFalse(scram.verify(serverFinal: goodFinal))
    }

    func testServerNonceMustExtendClientNonce() {
        var scram = client()
        XCTAssertThrowsError(try scram.clientFinalMessage(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        XCTAssertThrowsError(try scram.clientFinalMessage(
            serverFirst: "r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
    }
}
