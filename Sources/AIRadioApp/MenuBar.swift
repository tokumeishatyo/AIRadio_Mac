import AppKit
import AIRadioCore
import AIRadioInfra

/// メニューバー常駐 UI（仕様 s9）。📻 アイコン + メニューで放送の開始 / 停止。
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "停止中", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "放送を開始", action: nil, keyEquivalent: "")
    let session: BroadcastSession
    private var segmentCount = 0
    private var lastErrorCode: String?

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

    private func startBroadcast() async {
        let stack: BroadcastStack
        do {
            stack = try makeBroadcastStack(
                onBroadcastEvent: { [weak self] event in
                    printBroadcastEvent(event)
                    Task { @MainActor in self?.apply(event: event) }
                },
                onCornerEvent: printCornerEvent
            )
        } catch {
            showStartupError(error)
            return
        }
        segmentCount = stack.program.segments.count
        lastErrorCode = nil
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
        switch state {
        case .idle:
            toggleItem.title = "放送を開始"
            let suffix = lastErrorCode.map { "（直近エラー: \($0)）" } ?? ""
            stateItem.title = "停止中\(suffix)"
        case .broadcasting:
            toggleItem.title = "放送を停止"
            stateItem.title = "放送中…"
        }
    }

    private func apply(event: BroadcastEvent) {
        switch event {
        case .segmentStarted(let index, let kind):
            stateItem.title = "放送中: \(kind.rawValue) (\(index + 1)/\(segmentCount))"
        case .segmentFailed(_, _, let code, _):
            lastErrorCode = code
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
