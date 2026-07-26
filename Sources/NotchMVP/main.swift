import AppKit
import SwiftUI

// Entry point. Runs as a menu-bar accessory app (no Dock icon).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var notchController: NotchController?
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchController = NotchController()
        notchController?.show()
        setupStatusItem()
    }

    // A small menu-bar icon so the user can quit / relaunch the notch panel.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◗"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "NotchMVP", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Mở cùng macOS",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        menu.addItem(login)
        launchAtLoginItem = login

        menu.addItem(NSMenuItem(title: "Mở file cài đặt", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Tải lại cài đặt", action: #selector(reloadSettings), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Đặt lại vị trí notch", action: #selector(reposition), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Thoát", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        item.menu = menu
        statusItem = item
    }

    // Reflect the real state each time the menu opens — it can be changed from
    // System Settings or another copy of the app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        launchAtLoginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func openSettings() { SettingsStore.shared.openInEditor() }

    @objc private func reloadSettings() {
        SettingsStore.shared.reload()
        // Geometry and the shortcut both come from the file, so re-apply them.
        notchController?.applySettings()
    }

    @objc private func reposition() { notchController?.reposition() }
    @objc private func quit() { NSApp.terminate(nil) }
}
