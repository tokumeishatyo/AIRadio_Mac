import Foundation

/// アーティスト特集で特集する 1 組（`config/artists.yaml`。仕様 s15）。曲は持たず、実行時に top-tracks で確定する。
public struct ArtistProfile: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// アーティストの代表曲（top-tracks）取得の抽象（`SpotifyArtistCatalog` が準拠。テストで fake 差し替え）。
public protocol ArtistCatalog: Sendable {
    /// 指定アーティストの再生可能な代表曲を最大 `limit` 曲返す（重複・別バージョンの除外は呼び出し側）。
    func topTracks(artistName: String, limit: Int) async throws -> [TrackInfo]
}

/// アーティスト特集の発話パート（台本生成の種別。仕様 s15 §7）。
public enum ArtistFeaturePart: Sendable, Equatable {
    /// 導入（特集宣言＋アーティストへの思い一言）。
    case intro
    /// グループの曲紹介（その曲を正確な曲名で紹介）。
    case groupIntro(tracks: [TrackInfo])
    /// 感想（`shorter` = 2 回目以降の短い感想）。
    case comment(shorter: Bool)
}

/// アーティスト特集進行中の出来事（デモ表示・ログ用）。
public enum ArtistFeatureEvent: Sendable, Equatable {
    case artistSelected(name: String)
    case tracksPrepared(count: Int)
    case partScriptReady(lineCount: Int, totalCharacters: Int)
    case leadIn(String)
    case line(DialogueLine)
    case songStarted(TrackInfo)
    case songFinished(reason: TrackFinishReason)
    /// 特集をスキップ（プール空 or 再生可能曲不足）。reason に安定コードを含む（仕様 s15 §8-4）。
    case featureSkipped(reason: String)
}

/// 準備済みアーティスト特集（LLM + 検索 + TTS の成果物。先行準備で生成し本番で消費。仕様 s15 §8-3）。
/// `skipped` のときは本番で何も流さず `featureSkipped` を出す（プール空 or 曲不足）。
public struct PreparedArtistFeature: Sendable, Equatable {
    public let corner: CornerTemplate
    public let artist: ArtistProfile?
    /// 縮約後の曲グループ（例 7 曲なら `[[t1,t2,t3],[t4,t5,t6],[t7]]`）。
    public let groups: [[TrackInfo]]
    public let introScript: DialogueScript
    public let introAudio: [Data]
    /// 各グループの曲紹介台本（`groups` と同数・同順）。
    public let groupIntroScripts: [DialogueScript]
    public let groupIntroAudio: [[Data]]
    /// 各グループ後の感想台本（最後のグループの後は締めなので `groups.count - 1` 本）。
    public let commentScripts: [DialogueScript]
    public let commentAudio: [[Data]]
    /// 固定の締め（LLM 生成しない）。
    public let outroLine: DialogueLine
    public let outroAudio: Data
    public let castDjIds: [String]
    /// {artist} 置換済み・時刻のみ残したリード文（発話直前に時刻展開）。
    public let leadIn: String?
    public let leadInSpeakerId: Int
    public let skipped: Bool
    public let skipReason: String?

    public init(
        corner: CornerTemplate,
        artist: ArtistProfile?,
        groups: [[TrackInfo]],
        introScript: DialogueScript,
        introAudio: [Data],
        groupIntroScripts: [DialogueScript],
        groupIntroAudio: [[Data]],
        commentScripts: [DialogueScript],
        commentAudio: [[Data]],
        outroLine: DialogueLine,
        outroAudio: Data,
        castDjIds: [String],
        leadIn: String?,
        leadInSpeakerId: Int,
        skipped: Bool = false,
        skipReason: String? = nil
    ) {
        self.corner = corner
        self.artist = artist
        self.groups = groups
        self.introScript = introScript
        self.introAudio = introAudio
        self.groupIntroScripts = groupIntroScripts
        self.groupIntroAudio = groupIntroAudio
        self.commentScripts = commentScripts
        self.commentAudio = commentAudio
        self.outroLine = outroLine
        self.outroAudio = outroAudio
        self.castDjIds = castDjIds
        self.leadIn = leadIn
        self.leadInSpeakerId = leadInSpeakerId
        self.skipped = skipped
        self.skipReason = skipReason
    }

    /// スキップ用の準備物（プール空 or 曲不足。本番で featureSkipped を出して何も流さない）。
    public static func skip(corner: CornerTemplate, castDjIds: [String], reason: String) -> PreparedArtistFeature {
        PreparedArtistFeature(
            corner: corner, artist: nil, groups: [],
            introScript: DialogueScript(lines: []), introAudio: [],
            groupIntroScripts: [], groupIntroAudio: [],
            commentScripts: [], commentAudio: [],
            outroLine: DialogueLine(djId: "", text: ""), outroAudio: Data(),
            castDjIds: castDjIds, leadIn: nil, leadInSpeakerId: 0,
            skipped: true, skipReason: reason
        )
    }
}

/// アーティスト特集の準備（無音）と本番（発話 + 連続再生）。`ArtistFeatureEngine` が準拠（仕様 s15）。
public protocol ArtistFeatureRunning: Sendable {
    /// 準備: top-tracks 取得 → 縮約確定 → パート別台本 → 事前合成。`artist` が nil ならスキップ準備物を返す。
    func prepare(
        corner: CornerTemplate,
        artist: ArtistProfile?,
        djs: [DjProfile],
        castDjIds: [String],
        leadIn: String?
    ) async throws -> PreparedArtistFeature
    /// 本番: 導入 → （グループ紹介 → 連続再生 → 感想）×G → 締め。正常・例外・キャンセルいずれも最後は必ず pause。
    func run(prepared: PreparedArtistFeature, djs: [DjProfile]) async throws
}

/// アーティスト特集の実行（仕様 s15）。`CornerEngine` と同じ「prepare（無音）/ run（発話 + 曲 + 必ず pause）」二段構成。
/// 単曲モデルの `CornerEngine` と違い **複数曲を連続再生**し、発話が複数パートに分かれる。
public struct ArtistFeatureEngine: ArtistFeatureRunning, Sendable {
    /// top-tracks に要求する曲数（多めに取って重複除外後に絞る）。
    public static let fetchLimit = 10
    /// フル構成の曲数（3+3+1）。
    public static let targetTracks = 7
    /// 特集を実施する最低曲数（下回るとスキップ。仕様 s15 §6）。
    public static let minTracks = 3

    private let llm: any LLMBackend
    private let tts: any TTSBackend
    private let audio: any AudioPlayer
    private let catalog: any ArtistCatalog
    private let spotify: any SpotifyController
    private let clock: any Clock
    private let temperature: Double
    private let timeZone: TimeZone
    private let onEvent: (@Sendable (ArtistFeatureEvent) -> Void)?

    public init(
        llm: any LLMBackend,
        tts: any TTSBackend,
        audio: any AudioPlayer,
        catalog: any ArtistCatalog,
        spotify: any SpotifyController,
        clock: any Clock,
        temperature: Double = 0.9,
        timeZone: TimeZone = .current,
        onEvent: (@Sendable (ArtistFeatureEvent) -> Void)? = nil
    ) {
        self.llm = llm
        self.tts = tts
        self.audio = audio
        self.catalog = catalog
        self.spotify = spotify
        self.clock = clock
        self.temperature = temperature
        self.timeZone = timeZone
        self.onEvent = onEvent
    }

    // MARK: - 準備

    public func prepare(
        corner: CornerTemplate,
        artist: ArtistProfile?,
        djs: [DjProfile],
        castDjIds: [String],
        leadIn: String?
    ) async throws -> PreparedArtistFeature {
        let castIds = castDjIds.isEmpty ? corner.djIds : castDjIds
        let cast = try resolveCast(ids: castIds, djs: djs)

        // プール空: スキップ準備物（仕様 s15 §8-4、E-ART-EMPTY-POOL-001）。
        guard let artist else {
            return .skip(corner: corner, castDjIds: castIds,
                         reason: "E-ART-EMPTY-POOL-001: アーティストが未生成です（artists.yaml が空）")
        }
        onEvent?(.artistSelected(name: artist.name))

        // 曲の確定（top-tracks → 重複除外 → 最大 7）。プレフライト先行（CLAUDE.md §3-2）。
        let fetched = try await catalog.topTracks(artistName: artist.name, limit: Self.fetchLimit)
        let tracks = Array(Self.deduplicate(fetched).prefix(Self.targetTracks))
        onEvent?(.tracksPrepared(count: tracks.count))
        guard tracks.count >= Self.minTracks else {
            return .skip(corner: corner, castDjIds: castIds,
                         reason: "E-ART-INSUFFICIENT-TRACKS-001: 再生可能曲が \(tracks.count) 曲（最低 \(Self.minTracks) 必要）")
        }
        let groups = Self.splitGroups(tracks)
        let params = corner.artistFeatureParams ?? ArtistFeatureParams()
        let dateContext = SeasonPhrases.dateContext(date: clock.now, timeZone: timeZone)

        // パート別台本（導入 → 各グループ紹介 → 各感想。締めは固定文）。
        let introScript = try await generatePart(.intro, artist: artist, cast: cast,
                                                 dateContext: dateContext, target: params.introTargetChars)
        var groupIntroScripts: [DialogueScript] = []
        for group in groups {
            groupIntroScripts.append(try await generatePart(
                .groupIntro(tracks: group), artist: artist, cast: cast,
                dateContext: dateContext, target: params.groupIntroTargetChars))
        }
        var commentScripts: [DialogueScript] = []
        if groups.count >= 2 {
            for i in 0..<(groups.count - 1) {
                let shorter = i > 0   // 1 回目は長め、2 回目以降は短め（仕様 s15 §6）
                commentScripts.append(try await generatePart(
                    .comment(shorter: shorter), artist: artist, cast: cast, dateContext: dateContext,
                    target: shorter ? params.commentShortTargetChars : params.commentTargetChars))
            }
        }
        let outroLine = DialogueLine(djId: cast[0].id, text: params.outroLine)

        // 事前合成（本番の TTS 待ちゼロ。締めの固定文も合成）。
        let introAudio = try await synthesize(introScript, cast: cast)
        var groupIntroAudio: [[Data]] = []
        for script in groupIntroScripts { groupIntroAudio.append(try await synthesize(script, cast: cast)) }
        var commentAudio: [[Data]] = []
        for script in commentScripts { commentAudio.append(try await synthesize(script, cast: cast)) }
        let outroAudio = try await tts.synthesize(text: outroLine.text, speakerId: cast[0].speakerId)

        // リード文の {artist} を準備時に埋め、時刻プレースホルダのみ残す（発話直前に展開、仕様 s15 §4）。
        var leadInFilled = (leadIn?.isEmpty == false) ? leadIn : nil
        if var filled = leadInFilled {
            filled = filled.replacingOccurrences(of: "{artist}", with: artist.name)
            leadInFilled = filled
        }

        return PreparedArtistFeature(
            corner: corner, artist: artist, groups: groups,
            introScript: introScript, introAudio: introAudio,
            groupIntroScripts: groupIntroScripts, groupIntroAudio: groupIntroAudio,
            commentScripts: commentScripts, commentAudio: commentAudio,
            outroLine: outroLine, outroAudio: outroAudio,
            castDjIds: castIds, leadIn: leadInFilled,
            leadInSpeakerId: cast[0].speakerId
        )
    }

    private func generatePart(
        _ part: ArtistFeaturePart,
        artist: ArtistProfile,
        cast: [DjProfile],
        dateContext: String,
        target: Int
    ) async throws -> DialogueScript {
        let request = DialogueScriptGenerator.makeArtistFeatureRequest(
            part: part, artistName: artist.name, djs: cast,
            dateContext: dateContext, targetCharacters: target, temperature: temperature)
        let raw = try await llm.generate(request)
        let script = try DialogueScriptGenerator.parse(raw, djs: cast, minLines: 2)
        onEvent?(.partScriptReady(lineCount: script.lines.count, totalCharacters: script.totalCharacters))
        return script
    }

    private func synthesize(_ script: DialogueScript, cast: [DjProfile]) async throws -> [Data] {
        var audio: [Data] = []
        audio.reserveCapacity(script.lines.count)
        for line in script.lines {
            audio.append(try await tts.synthesize(text: line.text, speakerId: speakerId(for: line, cast: cast)))
        }
        return audio
    }

    // MARK: - 本番

    public func run(prepared: PreparedArtistFeature, djs: [DjProfile]) async throws {
        // スキップ（プール空 / 曲不足）は featureSkipped を出して何も流さない（仕様 s15 §8-4）。
        guard !prepared.skipped else {
            onEvent?(.featureSkipped(reason: prepared.skipReason ?? "スキップ"))
            return
        }
        let castIds = prepared.castDjIds.isEmpty ? prepared.corner.djIds : prepared.castDjIds
        do {
            let cast = try resolveCast(ids: castIds, djs: djs)
            try await perform(prepared: prepared, cast: cast)
        } catch {
            // 完全静寂（§3-1）: どの曲・どの発話でキャンセル/失敗しても、最後に play した URI を止め音量を戻す。
            await spotify.pauseIgnoringCancellation(restoringVolume: prepared.corner.volume)
            throw error
        }
        try await spotify.pause()
    }

    private func perform(prepared: PreparedArtistFeature, cast: [DjProfile]) async throws {
        // 0. リード文（時刻を発話直前に展開）。一過性失敗はスキップ、キャンセルは伝播（§3-1）。
        if let leadIn = prepared.leadIn, !leadIn.isEmpty {
            let values = TimePhrases.values(date: clock.now, timeZone: timeZone)
            let text = TemplateExpander.expand(leadIn, values: values)
            onEvent?(.leadIn(text))
            do {
                let wav = try await tts.synthesize(text: text, speakerId: prepared.leadInSpeakerId)
                try await audio.play(wav)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
            }
        }

        // 1. 導入
        try await speak(prepared.introScript, lineAudio: prepared.introAudio, cast: cast)

        // 2. （グループ紹介 → 連続再生 → 感想）×G。感想は最後のグループの後を除く。
        for index in prepared.groups.indices {
            try await speak(prepared.groupIntroScripts[index], lineAudio: prepared.groupIntroAudio[index], cast: cast)
            try await playGroup(prepared.groups[index], corner: prepared.corner)
            if index < prepared.groups.count - 1, index < prepared.commentScripts.count {
                try await speak(prepared.commentScripts[index], lineAudio: prepared.commentAudio[index], cast: cast)
            }
        }

        // 3. 締め（固定文）
        onEvent?(.line(prepared.outroLine))
        try await audio.play(prepared.outroAudio)
    }

    /// グループ内を連続再生（曲間に pause を挟まず次 URI を直接 play＝アトミック置換でシームレス）。
    private func playGroup(_ tracks: [TrackInfo], corner: CornerTemplate) async throws {
        for track in tracks {
            try await spotify.play(uri: track.uri)
            try await spotify.setVolume(corner.volume)
            onEvent?(.songStarted(track))
            if corner.playSeconds > 0 {
                try await clock.sleep(seconds: Double(corner.playSeconds))
            } else {
                let reason = try await spotify.waitForTrackToFinish(of: track.uri, clock: clock)
                onEvent?(.songFinished(reason: reason))
            }
        }
    }

    private func speak(_ script: DialogueScript, lineAudio: [Data], cast: [DjProfile]) async throws {
        if lineAudio.count == script.lines.count {
            for (line, wav) in zip(script.lines, lineAudio) {
                onEvent?(.line(line))
                try await audio.play(wav)
            }
            return
        }
        // 互換: 事前合成がなければその場で合成。
        for line in script.lines {
            onEvent?(.line(line))
            let wav = try await tts.synthesize(text: line.text, speakerId: speakerId(for: line, cast: cast))
            try await audio.play(wav)
        }
    }

    // MARK: - ヘルパー

    private func resolveCast(ids: [String], djs: [DjProfile]) throws -> [DjProfile] {
        let cast = try ids.map { id -> DjProfile in
            guard let dj = djs.first(where: { $0.id == id }) else {
                throw ConfigError.missingField("アーティスト特集の出演 DJ が未定義: \(id)")
            }
            return dj
        }
        guard !cast.isEmpty else {
            throw ConfigError.missingField("アーティスト特集の出演 DJ が空です")
        }
        return cast
    }

    private func speakerId(for line: DialogueLine, cast: [DjProfile]) -> Int {
        cast.first { $0.id == line.djId }?.speakerId ?? cast[0].speakerId
    }

    /// 同一 URI・同一の正規化タイトル（別バージョン）を除外する。
    public static func deduplicate(_ tracks: [TrackInfo]) -> [TrackInfo] {
        var seenUri = Set<String>()
        var seenTitle = Set<String>()
        var out: [TrackInfo] = []
        for track in tracks {
            if seenUri.contains(track.uri) { continue }
            let key = canonicalTitle(track.title)
            if !key.isEmpty, seenTitle.contains(key) { continue }
            seenUri.insert(track.uri)
            if !key.isEmpty { seenTitle.insert(key) }
            out.append(track)
        }
        return out
    }

    /// 重複判定用の正規化タイトル（小文字化・括弧内のバージョン表記除去・空白除去）。
    public static func canonicalTitle(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"[\(（\[【].*?[\)）\]】]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return s
    }

    /// 曲数 K を 3+3+1 ベースのグループへ分割（縮約。仕様 s15 §6）。例 7→[3,3,1] 6→[3,3] 5→[3,2] 4→[3,1] 3→[3]。
    public static func splitGroups(_ tracks: [TrackInfo]) -> [[TrackInfo]] {
        let count = tracks.count
        let front = min(3, count)
        let rem = count - front
        let mid = min(3, rem)
        let last = rem - mid
        var groups: [[TrackInfo]] = []
        var i = 0
        for size in [front, mid, last] where size > 0 {
            groups.append(Array(tracks[i..<(i + size)]))
            i += size
        }
        return groups
    }
}
