import Foundation
import Yams
import AIRadioCore

/// VOICEVOX 接続設定。
public struct TtsConfig: Sendable, Equatable {
    public var endpoint: String
    public var credit: String

    public init(endpoint: String, credit: String) {
        self.endpoint = endpoint
        self.credit = credit
    }
}

/// `config/tts.yaml` のローダ。
public enum TtsConfigLoader {
    private struct File: Decodable {
        struct Voicevox: Decodable {
            let endpoint: String?
            let credit: String?
        }
        let voicevox: Voicevox?
    }

    /// YAML 文字列から `TtsConfig` を構築する。
    public static func load(yaml: String) throws -> TtsConfig {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let voicevox = file.voicevox,
              let endpoint = voicevox.endpoint,
              !endpoint.isEmpty
        else {
            throw ConfigError.missingField("voicevox.endpoint")
        }
        return TtsConfig(endpoint: endpoint, credit: voicevox.credit ?? "")
    }

    /// ファイルパスから読み込む。
    public static func load(path: String) throws -> TtsConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
