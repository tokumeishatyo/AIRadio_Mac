import Foundation
import Yams
import AIRadioCore

/// VOICEVOX 接続設定。
public struct TtsConfig: Sendable, Equatable {
    public var endpoint: String
    public var credit: String
    /// 合成音声の再生音量（0.0–1.0）。Spotify の音楽とのバランス調整用。
    public var playbackVolume: Double
    /// 話速（VOICEVOX speedScale、1.0 = 標準。0.5–2.0 にクランプ）。
    public var speedScale: Double

    public init(endpoint: String, credit: String, playbackVolume: Double = 1.0, speedScale: Double = 1.0) {
        self.endpoint = endpoint
        self.credit = credit
        self.playbackVolume = min(max(playbackVolume, 0.0), 1.0)
        self.speedScale = min(max(speedScale, 0.5), 2.0)
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
        let playback_volume: Double?
        let speed_scale: Double?
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
        return TtsConfig(
            endpoint: endpoint,
            credit: voicevox.credit ?? "",
            playbackVolume: file.playback_volume ?? 1.0,
            speedScale: file.speed_scale ?? 1.0
        )
    }

    /// ファイルパスから読み込む。
    public static func load(path: String) throws -> TtsConfig {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
