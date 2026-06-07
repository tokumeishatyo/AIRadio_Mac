import Foundation

/// 安定エラーコードを持つ AIRadio 共通エラー。形式 `E-<CAT3>-<DETAIL>-<NNN>`。
public protocol RadioError: Error {
    var code: String { get }
    var message: String { get }
}

/// Spotify（検索 + AppleScript 再生）に関するエラー。
public enum SpotifyError: RadioError, Equatable {
    case noDevice
    case apiFailed(String)

    public var code: String {
        switch self {
        case .noDevice: return "E-SPT-NO-DEVICE-001"
        case .apiFailed: return "E-SPT-API-FAILED-001"
        }
    }

    public var message: String {
        switch self {
        case .noDevice:
            return "再生可能な Spotify が見つかりません（Spotify アプリを起動してください）"
        case .apiFailed(let detail):
            return "Spotify 操作に失敗しました: \(detail)"
        }
    }
}

/// 設定（YAML ロード・検証）に関するエラー。
public enum ConfigError: RadioError, Equatable {
    case missingField(String)

    public var code: String {
        switch self {
        case .missingField: return "E-CFG-MISSING-FIELD-001"
        }
    }

    public var message: String {
        switch self {
        case .missingField(let field):
            return "設定の必須フィールドが不足しています: \(field)"
        }
    }
}

/// TTS（VOICEVOX 等）に関するエラー。
public enum TtsError: RadioError, Equatable {
    case unreachable
    case synthesisFailed(String)

    public var code: String {
        switch self {
        case .unreachable: return "E-TTS-UNREACHABLE-001"
        case .synthesisFailed: return "E-TTS-SYNTHESIS-FAILED-001"
        }
    }

    public var message: String {
        switch self {
        case .unreachable:
            return "VOICEVOX に接続できません（VOICEVOX を起動してください）"
        case .synthesisFailed(let detail):
            return "音声合成に失敗しました: \(detail)"
        }
    }
}

/// 音声再生に関するエラー。
public enum AudioError: RadioError, Equatable {
    case playbackFailed

    public var code: String {
        switch self {
        case .playbackFailed: return "E-RTM-AUDIO-PLAYBACK-001"
        }
    }

    public var message: String {
        switch self {
        case .playbackFailed:
            return "音声の再生に失敗しました"
        }
    }
}
