import CryptoKit
import XCTest
@testable import Gonggi

final class GoogleOAuthPKCETests: XCTestCase {
    func testCodeVerifierLengthAndCharset() {
        let verifier = GoogleOAuthPKCE.makeCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testCodeChallengeS256MatchesKnownVector() {
        // RFC 7636 appendix B (base64url SHA256 of verifier)
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(GoogleOAuthPKCE.codeChallengeS256(for: verifier), expected)
    }

    func testStateIsNonEmptyAndDistinct() {
        let a = GoogleOAuthPKCE.makeState()
        let b = GoogleOAuthPKCE.makeState()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b)
    }
}
