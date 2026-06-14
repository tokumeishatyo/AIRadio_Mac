import Testing
import Foundation
@testable import AIRadioInfra

struct ConfigLocationTests {
    @Test("env 指定が最優先（.app の親より優先）")
    func envWins() {
        let r = ConfigLocation.resolve(
            envOverride: "/custom/cfg",
            appBundleParent: URL(fileURLWithPath: "/Applications"))
        #expect(r == "/custom/cfg")
    }

    @Test(".app の親ディレクトリ/config")
    func appBundleParent() {
        let r = ConfigLocation.resolve(
            envOverride: nil,
            appBundleParent: URL(fileURLWithPath: "/Users/me/AIRadio"))
        #expect(r == "/Users/me/AIRadio/config")
    }

    @Test("dev（env なし・.app でない）は cwd 相対 config")
    func devFallback() {
        #expect(ConfigLocation.resolve(envOverride: nil, appBundleParent: nil) == "config")
        // 空文字の env は無視してフォールバックする。
        #expect(ConfigLocation.resolve(envOverride: "", appBundleParent: nil) == "config")
    }
}
