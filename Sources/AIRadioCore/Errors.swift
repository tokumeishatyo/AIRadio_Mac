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
    case authFailed(String)
    case authRequired
    case searchFailed(String)

    public var code: String {
        switch self {
        case .noDevice: return "E-SPT-NO-DEVICE-001"
        case .apiFailed: return "E-SPT-API-FAILED-001"
        case .authFailed: return "E-SPT-AUTH-FAILED-001"
        case .authRequired: return "E-SPT-AUTH-REQUIRED-001"
        case .searchFailed: return "E-SPT-SEARCH-FAILED-001"
        }
    }

    public var message: String {
        switch self {
        case .noDevice:
            return "再生可能な Spotify が見つかりません（Spotify アプリを起動してください）"
        case .apiFailed(let detail):
            return "Spotify 操作に失敗しました: \(detail)"
        case .authFailed(let detail):
            return "Spotify 認証に失敗しました（client_id / redirect_uri を確認してください）: \(detail)"
        case .authRequired:
            return "Spotify にログインしてください（AIRADIO_DEMO=spotify-auth で認証）"
        case .searchFailed(let detail):
            return "Spotify 検索に失敗しました: \(detail)"
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

/// リサーチ（ニュース / 天気）に関するエラー。
public enum ResearchError: RadioError, Equatable {
    case newsFetchFailed(String)
    case weatherFetchFailed(String)

    public var code: String {
        switch self {
        case .newsFetchFailed: return "E-NEWS-FETCH-FAILED-001"
        case .weatherFetchFailed: return "E-WX-FETCH-FAILED-001"
        }
    }

    public var message: String {
        switch self {
        case .newsFetchFailed(let detail):
            return "ニュースの取得に失敗しました: \(detail)"
        case .weatherFetchFailed(let detail):
            return "天気予報の取得に失敗しました: \(detail)"
        }
    }
}

/// LLM（Gemini / Gemma）に関するエラー。
/// キー欠落は fail-fast、それ以外は fail-tolerant（コーナー中断 + 静寂、放送自体は継続）。
public enum LLMError: RadioError, Equatable {
    case keyMissing
    case apiFailed(String)
    case emptyResponse
    case scriptParseFailed(String)

    public var code: String {
        switch self {
        case .keyMissing: return "E-LLM-KEY-MISSING-001"
        case .apiFailed: return "E-LLM-API-FAILED-001"
        case .emptyResponse: return "E-LLM-EMPTY-RESPONSE-001"
        case .scriptParseFailed: return "E-LLM-SCRIPT-PARSE-FAILED-001"
        }
    }

    public var message: String {
        switch self {
        case .keyMissing:
            return "Gemini API キーが見つかりません（config/llm.local.yaml.sample をコピーして"
                + " config/llm.local.yaml に api_key を設定してください）"
        case .apiFailed(let detail):
            return "LLM リクエストに失敗しました: \(detail)"
        case .emptyResponse:
            return "LLM の応答にテキストが含まれていません"
        case .scriptParseFailed(let detail):
            return "LLM 応答を台本として解釈できませんでした: \(detail)"
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
