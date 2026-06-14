import Foundation
import AIRadioInfra

/// config ファイルのパスを解決する（仕様 s20）。
/// - `.app` バンドル内で動いていれば **.app と同じ階層の `config/`**（自己完結フォルダ）。
/// - dev（`swift run`）や直接実行なら **cwd 相対 `config/`**（現行どおり・挙動不変）。
/// - 環境変数 `AIRADIO_CONFIG_DIR` で常に上書き可。
func configPath(_ name: String) -> String {
    let env = ProcessInfo.processInfo.environment["AIRADIO_CONFIG_DIR"]
    let bundleURL = Bundle.main.bundleURL
    let appBundleParent = bundleURL.pathExtension == "app" ? bundleURL.deletingLastPathComponent() : nil
    let base = ConfigLocation.resolve(envOverride: env, appBundleParent: appBundleParent)
    return (base as NSString).appendingPathComponent(name)
}
