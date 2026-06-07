import Testing
import Foundation
@testable import AIRadioInfra

struct PKCETests {
    // RFC 7636 Appendix B のテストベクタ
    @Test func challengeMatchesRfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsUrlSafeAndLongEnough() {
        let verifier = PKCE.generateVerifier()
        #expect(verifier.count >= 43)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
    }
}
