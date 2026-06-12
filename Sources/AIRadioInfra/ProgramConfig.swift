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
            if kind == .talk {
                guard let cornerId = segment.corner_id, !cornerId.isEmpty else {
                    throw ConfigError.missingField("program.segments[\(index)].corner_id (talk)")
                }
                return ProgramSegment(kind: kind, cornerId: cornerId)
            }
            return ProgramSegment(kind: kind)
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
