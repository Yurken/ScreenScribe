import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PresentationController()
    private var status: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        let submenu = NSMenu()
        let toolbarItem = submenu.addItem(withTitle: "批注工具条", action: #selector(focusToolbar), keyEquivalent: "t")
        toolbarItem.keyEquivalentModifierMask = [.command, .option]
        toolbarItem.target = self
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "退出屏注", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.submenu = submenu
        menu.addItem(appMenu)
        let editMenu = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editing = NSMenu(title: "编辑")
        editing.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editing.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editing.addItem(.separator())
        editing.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editing.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editing.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editing.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.submenu = editing
        menu.addItem(editMenu)
        NSApp.mainMenu = menu
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "屏注 ScreenScribe")
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ControlPanel(controller: controller))
        controller.closePanel = { [weak self] in self?.popover.performClose(nil) }
        controller.showPanel = { [weak self] in self?.openPanel() }
        controller.recordingChanged = { [weak self] active in
            self?.status.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "pencil.tip.crop.circle", accessibilityDescription: active ? "正在录屏" : "屏注")
            self?.status.button?.contentTintColor = active ? .systemRed : nil
        }
        controller.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            openPanel()
        }
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开屏注", action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出屏注", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.first?.target = self
            status.menu = menu
            status.button?.performClick(nil)
            status.menu = nil
        } else if popover.isShown { popover.performClose(nil) } else { openPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
    }

    @objc private func focusToolbar() { controller.focusToolbar() }

    private func openPanel() {
        guard let button = status.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.recording.isRecording || controller.recording.isBusy {
            Task {
                while controller.recording.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                await controller.stopRecording()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
