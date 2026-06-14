import AppKit
import AIRadioCore
import AIRadioInfra

/// メニューバー常駐 UI（仕様 s9 + s13）。📻 アイコン + メニューで放送の開始 / 停止 /
/// ED で終了 / 番組の長さ（UserDefaults 保持）。
@MainActor
final class MenuBarController: NSObject, NSMenuItemValidation {
    /// メニュー「番組の長さ」の選択肢（仕様 s13 §5）。
    private static let lengthChoices: [ProgramLength] = [
        .corners(10), .corners(20), .corners(30), .endless,
    ]

    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "停止中", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "放送を開始", action: nil, keyEquivalent: "")
    private let endingItem = NSMenuItem(title: "ED で終了", action: nil, keyEquivalent: "")
    private let generateArtistsItem = NSMenuItem(title: "アーティスト一覧を生成", action: nil, keyEquivalent: "")
    private let lengthMenu = NSMenu()
    let session: BroadcastSession
    private var segmentCountLabel = "?"
    private var lastErrorCode: String?
    private var isBroadcasting = false
    /// アーティスト一覧の生成中か（放送と相互排他。仕様 s15 §9-3）。
    private var isGeneratingArtists = false
    private var generateTask: Task<Void, Never>?
    /// 放送中の操作ハンドル（「ED で終了」用。放送開始時にセット、idle で破棄）。
    private var activeControl: BroadcastControl?

    override init() {
        // onStateChange は self 確定前に作るため、弱参照ボックス経由で UI へ届ける。
        final class WeakBox: @unchecked Sendable { weak var controller: MenuBarController? }
        let box = WeakBox()
        session = BroadcastSession(onStateChange: { state in
            Task { @MainActor in box.controller?.apply(state: state) }
        })
        super.init()
        box.controller = self

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        toggleItem.target = self
        toggleItem.action = #selector(toggleBroadcast)
        menu.addItem(toggleItem)
        endingItem.target = self
        endingItem.action = #selector(requestEnding)
        menu.addItem(endingItem)
        menu.addItem(.separator())

        // 番組の長さ（次の放送開始から反映。UserDefaults に保持、既定値は program.yaml）。
        let lengthItem = NSMenuItem(title: "番組の長さ", action: nil, keyEquivalent: "")
        for choice in Self.lengthChoices {
            let item = NSMenuItem(title: programLengthLabel(choice), action: #selector(selectLength(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            lengthMenu.addItem(item)
        }
        lengthItem.submenu = lengthMenu
        menu.addItem(lengthItem)
        refreshLengthCheckmarks()

        // アーティスト一覧を生成（放送停止時のみ。生成中は放送開始を抑止＝相互排他。仕様 s15 §9-3）。
        generateArtistsItem.target = self
        generateArtistsItem.action = #selector(generateArtists)
        menu.addItem(generateArtistsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📻"
        statusItem.menu = menu
    }

    @objc private func toggleBroadcast() {
        Task {
            if await session.state == .broadcasting {
                await session.stop()
            } else {
                await startBroadcast()
            }
        }
    }

    /// 「ED で終了」: 現在のセグメント（+ 準備済みの直後トーク）を流したら ED で締める（仕様 s13 §4）。
    @objc private func requestEnding() {
        activeControl?.requestEnding()
        stateItem.title = "放送中…（ED で終了します）"
    }

    /// アーティスト一覧を生成（放送停止時のみ。生成中は放送開始を抑止＝相互排他。仕様 s15 §9-3）。
    /// `artist-gen.yaml` の genre_prompt/target_count に従い LLM 生成 → Spotify 検証 → artists.yaml を上書き。
    @objc private func generateArtists() {
        guard !isBroadcasting, !isGeneratingArtists else { return }
        isGeneratingArtists = true
        generateArtistsItem.title = "アーティスト生成中…"
        stateItem.title = "アーティスト一覧を生成中…"
        generateTask = Task { [weak self] in
            do {
                let (generator, config) = try makeArtistListGenerator()
                let count = try await generator.generate(config: config, writingTo: "config/artists.yaml")
                self?.finishGenerating(result: .success(count))
            } catch is CancellationError {
                self?.finishGenerating(result: .success(-1))   // 中止
            } catch {
                self?.finishGenerating(result: .failure(error))
            }
        }
    }

    private func finishGenerating(result: Result<Int, any Error>) {
        isGeneratingArtists = false
        generateTask = nil
        generateArtistsItem.title = "アーティスト一覧を生成"
        switch result {
        case .success(let count) where count >= 0:
            stateItem.title = "停止中（アーティスト \(count) 組を生成）"
        case .success:
            stateItem.title = "停止中"   // 中止
        case .failure(let error):
            stateItem.title = "停止中（生成エラー）"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "アーティスト一覧の生成に失敗しました"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func selectLength(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: programLengthDefaultsKey)
        refreshLengthCheckmarks()
    }

    private func refreshLengthCheckmarks() {
        let current = currentLengthSelection()
        for item in lengthMenu.items {
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
    }

    /// 現在の選択値（UserDefaults → program.yaml の既定値の順）。
    private func currentLengthSelection() -> ProgramLength {
        let defaultLength = (try? ProgramConfigLoader.load(path: "config/program.yaml"))?.defaultLength
            ?? .corners(10)
        return selectedProgramLength(defaultLength: defaultLength)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === endingItem { return isBroadcasting && activeControl != nil }
        // 生成中はボタン無効、放送中もボタン無効（相互排他）。
        if menuItem === generateArtistsItem { return !isBroadcasting && !isGeneratingArtists }
        // 生成中は「放送を開始」を無効化（放送中なら「停止」として有効）。
        if menuItem === toggleItem { return isBroadcasting || !isGeneratingArtists }
        return true
    }

    private func startBroadcast() async {
        guard !isGeneratingArtists else { return }   // 生成中は開始しない（相互排他）。
        let stack: BroadcastStack
        do {
            stack = try makeBroadcastStack(
                onBroadcastEvent: { [weak self] event in
                    printBroadcastEvent(event)
                    Task { @MainActor in self?.apply(event: event) }
                },
                onCornerEvent: printCornerEvent,
                onArtistFeatureEvent: printArtistFeatureEvent
            )
        } catch {
            showStartupError(error)
            return
        }
        segmentCountLabel = stack.plan.totalSegmentCount.map(String.init) ?? "∞"
        lastErrorCode = nil
        activeControl = stack.control
        await session.start {
            do {
                try await stack.run()
            } catch is CancellationError {
                print("停止しました（完全静寂）")
            } catch let error as RadioError {
                print("エラー[\(error.code)]: \(error.message)")
            } catch {
                print("エラー: \(error)")
            }
        }
    }

    private func apply(state: BroadcastSession.State) {
        isBroadcasting = state == .broadcasting
        switch state {
        case .idle:
            toggleItem.title = "放送を開始"
            let suffix = lastErrorCode.map { "（直近エラー: \($0)）" } ?? ""
            stateItem.title = "停止中\(suffix)"
            activeControl = nil
        case .broadcasting:
            toggleItem.title = "放送を停止"
            stateItem.title = "放送中…"
        }
    }

    private func apply(event: BroadcastEvent) {
        switch event {
        case .segmentStarted(let index, let kind):
            stateItem.title = "放送中: \(kind.rawValue) (\(index + 1)/\(segmentCountLabel))"
        case .segmentFailed(_, _, let code, _):
            lastErrorCode = code
        case .endingRequested:
            stateItem.title = "放送中…（ED で終了します）"
        case .segmentFinished, .songStarted, .songFinished, .broadcastFinished:
            break
        }
    }

    private func showStartupError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "放送を開始できません"
        if let radioError = error as? RadioError {
            alert.informativeText = "[\(radioError.code)] \(radioError.message)"
        } else {
            alert.informativeText = String(describing: error)
        }
        alert.runModal()
    }
}

/// 終了時に放送を確実に止めてからアプリを閉じる（鳴らしっぱなし防止、CLAUDE.md §3-1）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = controller?.session else { return .terminateNow }
        Task {
            await session.stopAndWait()  // pause 後始末の完了まで待つ
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// メニューバー常駐モードのエントリ（`AIRADIO_DEMO` なしの既定）。
@MainActor
func runMenuBarApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // Dock に出さない常駐
    let delegate = AppDelegate()
    app.delegate = delegate
    print("ケイラボAIラジオ — メニューバーに常駐します（📻 から開始 / 停止）")
    app.run()
}
