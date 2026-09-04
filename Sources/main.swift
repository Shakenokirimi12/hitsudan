import AppKit
import ServiceManagement

/// The app lives in the menu bar. It only opens a window while the tablet is
/// plugged in and its reports are readable, and puts that window on the
/// tablet's own display.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: MainWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        let board = MainWindowController()
        board.onPresenceChange = { [weak self] present in
            self?.refresh()
            if present { NSApp.activate(ignoringOtherApps: false) }
        }
        controller = board
        refresh()
    }

    /// Closing the board must not end the agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.releasePointer()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbol = NSImage(systemSymbolName: "applepencil", accessibilityDescription: "筆談ボード")
            ?? NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "筆談ボード")
        symbol?.isTemplate = true
        item.button?.image = symbol
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func refresh() {
        if let menu = statusItem?.menu { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let present = controller?.isTabletPresent ?? false

        let state = NSMenuItem(title: present ? "Kamvas 13 接続中" : "タブレット未接続",
                               action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "ボードを表示", action: #selector(showBoard(_:)), keyEquivalent: "")
        show.target = self
        show.isEnabled = present
        menu.addItem(show)

        let pointerItem = NSMenuItem(title: "ペンでカーソル操作",
                                     action: #selector(togglePointer(_:)), keyEquivalent: "")
        pointerItem.target = self
        pointerItem.state = (controller?.isPointerEnabled ?? false) ? .on : .off
        pointerItem.isEnabled = present
        menu.addItem(pointerItem)

        menu.addItem(.separator())

        let widgets = NSMenuItem(title: "ウィジェット", action: nil, keyEquivalent: "")
        let widgetMenu = NSMenu()
        for entry in controller?.widgetMenuItems ?? [] {
            let row = NSMenuItem(title: entry.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            row.target = self
            row.state = entry.visible ? .on : .off
            row.representedObject = entry.id
            widgetMenu.addItem(row)
        }
        widgets.submenu = widgetMenu
        widgets.isEnabled = present
        menu.addItem(widgets)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func showBoard(_ sender: Any?) {
        controller?.comeForward()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePointer(_ sender: NSMenuItem) {
        controller?.setPointerEnabled(sender.state != .on)
        refresh()
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller?.toggleWidget(id)
        refresh()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        refresh()
    }
}

private func item(_ title: String, _ action: Selector?, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = modifiers
    return i
}

private func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(item("ボードを閉じる", #selector(MainWindowController.hideBoard(_:)), "w"))
    appMenu.addItem(item("筆談ボードを隠す", #selector(NSApplication.hide(_:)), "h"))
    appMenu.addItem(.separator())
    appMenu.addItem(item("終了", #selector(NSApplication.terminate(_:)), "q"))
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "ファイル")
    fileMenu.addItem(item("画像を読み込む…", #selector(MainWindowController.openImage(_:)), "o"))
    fileMenu.addItem(item("PNG で書き出す…", #selector(MainWindowController.exportPNG(_:)), "s"))
    fileMenu.addItem(.separator())
    fileMenu.addItem(item("新しいページ", #selector(MainWindowController.newPage(_:)), "n"))
    fileMenu.addItem(item("前のページ", #selector(MainWindowController.previousPage(_:)), "["))
    fileMenu.addItem(item("次のページ", #selector(MainWindowController.nextPage(_:)), "]"))
    fileMenu.addItem(item("このページを削除…", #selector(MainWindowController.deletePage(_:)), ""))
    fileMenu.addItem(item("空のページを整理", #selector(MainWindowController.purgeEmptyPages(_:)), ""))
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "編集")
    editMenu.addItem(item("元に戻す", #selector(MainWindowController.undoStroke(_:)), "z"))
    editMenu.addItem(item("やり直す", #selector(MainWindowController.redoStroke(_:)), "z", [.command, .shift]))
    editMenu.addItem(.separator())
    editMenu.addItem(item("コピー", #selector(NSText.copy(_:)), "c"))
    editMenu.addItem(item("ペースト", #selector(NSText.paste(_:)), "v"))
    editMenu.addItem(item("すべて選択", #selector(NSText.selectAll(_:)), "a"))
    editMenu.addItem(.separator())
    editMenu.addItem(item("すべて消去", #selector(MainWindowController.clearCanvas(_:)), "k", [.command, .shift]))
    editItem.submenu = editMenu
    main.addItem(editItem)

    let runItem = NSMenuItem()
    let runMenu = NSMenu(title: "セッション")
    runMenu.addItem(item("送る", #selector(MainWindowController.send(_:)), "\r"))
    runItem.submenu = runMenu
    main.addItem(runItem)

    NSApp.mainMenu = main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
buildMenu()
app.run()
