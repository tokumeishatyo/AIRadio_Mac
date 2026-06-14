import Foundation

/// config ベースディレクトリの解決（仕様 s20）。ダブルクリック起動（.app）と `swift run`（dev）で
/// 作業ディレクトリが変わるため、config の場所を一元的に決める純ロジック。
public enum ConfigLocation {
    /// 解決の優先順:
    /// 1. `envOverride`（環境変数 `AIRADIO_CONFIG_DIR`）が非空ならそれ。
    /// 2. `appBundleParent`（.app の親ディレクトリ）があれば `<parent>/config`（＝.app と同じ階層の config/）。
    /// 3. どちらも無ければ cwd 相対 `config`（dev `swift run`・直接実行。現行どおり）。
    public static func resolve(envOverride: String?, appBundleParent: URL?) -> String {
        if let env = envOverride, !env.isEmpty { return env }
        if let parent = appBundleParent {
            return parent.appendingPathComponent("config").path
        }
        return "config"
    }
}
