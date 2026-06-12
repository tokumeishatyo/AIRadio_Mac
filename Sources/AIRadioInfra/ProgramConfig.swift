import Foundation
import Yams
import AIRadioCore

/// `config/program.yaml` のローダ（番組フォーマット）。
public enum ProgramConfigLoader {
    private struct File: Decodable {
        struct ProgramSection: Decodable {
            struct Segment: Decodable {
                let type: String?
                let corner_id: String?
                let critical: Bool?
                let dj_id: String?
                let song_prompt_hint: String?
                let fallback_track_uri: String?
                let volume: Int?
                let play_seconds: Int?
            }
            let title: String?
            let anchor_dj_id: String?
            let segments: [Segment]?
        }
        let program: ProgramSection?
    }

    public static func load(yaml: String) throws -> Program {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let program = file.program else {
            throw ConfigError.missingField("program")
        }
        guard let anchorDjId = program.anchor_dj_id, !anchorDjId.isEmpty else {
            throw ConfigError.missingField("program.anchor_dj_id")
        }
        guard let segments = program.segments, !segments.isEmpty else {
            throw ConfigError.missingField("program.segments")
        }
        let parsed = try segments.enumerated().map { index, segment -> ProgramSegment in
            guard let raw = segment.type, let kind = SegmentKind(rawValue: raw) else {
                throw ConfigError.missingField(
                    "program.segments[\(index)].type が不正: \(segment.type ?? "(なし)")")
            }
            switch kind {
            case .talk:
                guard let cornerId = segment.corner_id, !cornerId.isEmpty else {
                    throw ConfigError.missingField("program.segments[\(index)].corner_id (talk)")
                }
                return ProgramSegment(
                    kind: kind, cornerId: cornerId,
                    critical: segment.critical ?? false, djId: segment.dj_id
                )
            case .song:
                guard let fallback = segment.fallback_track_uri, !fallback.isEmpty else {
                    throw ConfigError.missingField("program.segments[\(index)].fallback_track_uri (song)")
                }
                return ProgramSegment(
                    kind: kind,
                    critical: segment.critical ?? false,
                    song: SongSegmentSpec(
                        promptHint: segment.song_prompt_hint ?? "",
                        fallbackTrackUri: SpotifyURI.normalizeTrack(fallback),
                        volume: segment.volume ?? 100,
                        playSeconds: segment.play_seconds ?? 0
                    )
                )
            default:
                return ProgramSegment(kind: kind, critical: segment.critical ?? false, djId: segment.dj_id)
            }
        }
        return Program(
            title: program.title ?? "ケイラボAIラジオ",
            anchorDjId: anchorDjId,
            segments: parsed
        )
    }

    public static func load(path: String) throws -> Program {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
