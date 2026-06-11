import Foundation
import Yams
import AIRadioCore

/// `config/djs.yaml` のローダ（番組 DJ の一覧）。
public enum DjsConfigLoader {
    private struct File: Decodable {
        struct Dj: Decodable {
            let id: String?
            let name: String?
            let speaker_id: Int?
            let persona: String?
        }
        let djs: [Dj]?
    }

    public static func load(yaml: String) throws -> [DjProfile] {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let djs = file.djs, !djs.isEmpty else {
            throw ConfigError.missingField("djs")
        }
        return try djs.map { dj in
            guard let id = dj.id, !id.isEmpty else { throw ConfigError.missingField("djs[].id") }
            guard let name = dj.name, !name.isEmpty else { throw ConfigError.missingField("djs[].name (\(id))") }
            guard let speakerId = dj.speaker_id else { throw ConfigError.missingField("djs[].speaker_id (\(id))") }
            return DjProfile(id: id, name: name, speakerId: speakerId, persona: dj.persona ?? "")
        }
    }

    public static func load(path: String) throws -> [DjProfile] {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
