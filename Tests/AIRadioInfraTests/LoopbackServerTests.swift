import Testing
@testable import AIRadioInfra

struct LoopbackServerTests {
    @Test func extractsCodeFromRequestLine() {
        let request = "GET /callback?code=ABC123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:5543\r\n\r\n"
        #expect(LoopbackServer.queryItem("code", in: request) == "ABC123")
        #expect(LoopbackServer.queryItem("state", in: request) == "xyz")
    }

    @Test func extractsErrorParam() {
        let request = "GET /callback?error=access_denied HTTP/1.1\r\n\r\n"
        #expect(LoopbackServer.queryItem("error", in: request) == "access_denied")
        #expect(LoopbackServer.queryItem("code", in: request) == nil)
    }

    @Test func percentDecodesValue() {
        let request = "GET /callback?code=a%20b HTTP/1.1\r\n\r\n"
        #expect(LoopbackServer.queryItem("code", in: request) == "a b")
    }
}
