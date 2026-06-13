import Foundation
import Yams
import AIRadioCore

/// `config/program.yaml` のローダ（v2: 部品宣言。セグメント列はここから生成する、仕様 s13 §6）。
public enum ProgramConfigLoader {
    private struct File: Decodable {
        struct ProgramSection: Decodable {
            struct Opening: Decodable {
                let critical: Bool?
            }
            struct Song: Decodable {
                let song_prompt_hint: String?
                let fallback_track_uri: String?
                let volume: Int?
                let play_seconds: Int?
            }
            struct Talk: Decodable {
                let corner_id: String?
            }
            struct News: Decodable {
                let dj_id: String?
            }
            let title: String?
            let anchor_dj_id: String?
            let default_length: LengthValue?
            let opening: Opening?
            let song: Song?
            let talk: Talk?
            let letter: Talk?
            let news: News?
            let weekly_cast: [String: [String]]?
            let guest: Talk?
            let artist_feature: Talk?
        }
        let program: ProgramSection?
    }

    /// 曜日名 → Calendar の weekday（1=日…7=土）。
    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func parseWeeklyCast(_ raw: [String: [String]]?) throws -> WeeklyCast {
        guard let raw, !raw.isEmpty else { return .standard }
        var casts: [Int: [String]] = [:]
        for (day, ids) in raw {
            guard let weekday = weekdayNumbers[day.lowercased()] else {
                throw ConfigError.missingField("program.weekly_cast の曜日名が不正: \(day)")
            }
            guard !ids.isEmpty else {
                throw ConfigError.missingField("program.weekly_cast.\(day) の編成が空です")
            }
            casts[weekday] = ids
        }
        return WeeklyCast(casts: casts)
    }

    /// `default_length` の値（整数 `10` / 文字列 `"10"` / `endless` を受ける）。
    private struct LengthValue: Decodable {
        let length: ProgramLength

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let count = try? container.decode(Int.self) {
                guard count >= 1 else {
                    throw ConfigError.missingField("program.default_length は 1 以上（または endless）: \(count)")
                }
                length = .corners(count)
                return
            }
            if let raw = try? container.decode(String.self),
               let parsed = ProgramLength(rawValue: raw) {
                if case .corners(let count) = parsed, count < 1 {
                    throw ConfigError.missingField("program.default_length は 1 以上（または endless）: \(raw)")
                }
                length = parsed
                return
            }
            throw ConfigError.missingField("program.default_length が不正（数値または endless）")
        }
    }

    public static func load(yaml: String) throws -> ProgramBlueprint {
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: yaml)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.missingField("program.yaml を解釈できません: \(error)")
        }
        guard let program = file.program else {
            throw ConfigError.missingField("program")
        }
        guard let anchorDjId = program.anchor_dj_id, !anchorDjId.isEmpty else {
            throw ConfigError.missingField("program.anchor_dj_id")
        }
        guard let song = program.song else {
            throw ConfigError.missingField("program.song")
        }
        guard let fallback = song.fallback_track_uri, !fallback.isEmpty else {
            throw ConfigError.missingField("program.song.fallback_track_uri")
        }
        guard let talkCornerId = program.talk?.corner_id, !talkCornerId.isEmpty else {
            throw ConfigError.missingField("program.talk.corner_id")
        }
        guard let letterCornerId = program.letter?.corner_id, !letterCornerId.isEmpty else {
            throw ConfigError.missingField("program.letter.corner_id")
        }
        return ProgramBlueprint(
            title: program.title ?? "ケイラボAIラジオ",
            anchorDjId: anchorDjId,
            defaultLength: program.default_length?.length ?? .corners(10),
            openingCritical: program.opening?.critical ?? true,
            song: SongSegmentSpec(
                promptHint: song.song_prompt_hint ?? "",
                fallbackTrackUri: SpotifyURI.normalizeTrack(fallback),
                volume: song.volume ?? 100,
                playSeconds: song.play_seconds ?? 0
            ),
            talkCornerId: talkCornerId,
            letterCornerId: letterCornerId,
            newsDjId: program.news?.dj_id,
            weeklyCast: try parseWeeklyCast(program.weekly_cast),
            guestCornerId: program.guest?.corner_id,
            artistFeatureCornerId: program.artist_feature?.corner_id
        )
    }

    public static func load(path: String) throws -> ProgramBlueprint {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
