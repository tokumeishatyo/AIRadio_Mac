import Foundation
import Yams
import AIRadioCore

/// `config/guests.yaml` のローダ（ゲストコーナーのゲストプール。仕様 s14）。
/// 構造は djs.yaml と同形（id / name / speaker_id / persona）。レギュラーとは別ファイルで管理する。
public enum GuestsConfigLoader {
    private struct File: Decodable {
        struct Guest: Decodable {
            let id: String?
            let name: String?
            let speaker_id: Int?
            let persona: String?
        }
        let guests: [Guest]?
    }

    public static func load(yaml: String) throws -> [DjProfile] {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        guard let guests = file.guests, !guests.isEmpty else {
            throw ConfigError.missingField("guests")
        }
        return try guests.map { guest in
            guard let id = guest.id, !id.isEmpty else { throw ConfigError.missingField("guests[].id") }
            guard let name = guest.name, !name.isEmpty else { throw ConfigError.missingField("guests[].name (\(id))") }
            guard let speakerId = guest.speaker_id else { throw ConfigError.missingField("guests[].speaker_id (\(id))") }
            return DjProfile(id: id, name: name, speakerId: speakerId, persona: guest.persona ?? "")
        }
    }

    public static func load(path: String) throws -> [DjProfile] {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try load(yaml: yaml)
    }
}
