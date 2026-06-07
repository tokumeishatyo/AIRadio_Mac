import Foundation

/// `{key}` 形式のプレースホルダを値で置換する純粋ユーティリティ。
/// オープニング前口上・コーナーテンプレ等の展開に使う土台。
public enum TemplateExpander {
    /// `template` 内の `{key}` を `values[key]` で置換する。
    /// 未知のプレースホルダ（values に無いキー）は原文のまま残す。
    public static func expand(_ template: String, values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
