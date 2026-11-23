import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "MiVoice"
        item.button?.image = menuBarImage()
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        model.start()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
            .store(in: &cancellables)
        refreshStatusIcon()

        if !UserDefaults.standard.bool(forKey: "hasShownSettings") {
            UserDefaults.standard.set(true, forKey: "hasShownSettings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopMacMicMonitor()
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addDisabled(menu, model.linkState.text)
        addDisabled(menu, "按键：\(model.hidMode.text)")
        addDisabled(menu, "语音：\(model.voiceStatusText)")
        menu.addItem(.separator())

        add(menu, "打开设置…", #selector(showSettings), ",")
        add(menu, "重新连接遥控器", #selector(reconnectRemote), "")
        add(menu, "复制诊断信息", #selector(copyDiagnostics), "")

        if !model.accessibilityGranted || !model.inputMonitoringGranted {
            add(menu, "需要授予权限…", #selector(showSettings), "")
        }

        menu.addItem(.separator())
        add(menu, "退出 MiVoice", #selector(quit), "q")
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MiVoice 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 740, height: 780))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.startMacMicMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopMacMicMonitor()
    }

    @objc private func reconnectRemote() {
        model.reconnectRemote()
    }

    @objc private func copyDiagnostics() {
        model.copyDiagnostics()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func refreshStatusIcon() {
        guard let statusItem else { return }
        let image: NSImage?
        if model.isRecording {
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MiVoice 正在听")
        } else {
            switch model.linkState {
            case .failed, .unauthorized, .bluetoothOff:
                image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "MiVoice 未连接")
            default:
                image = menuBarImage()
            }
        }
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Custom mic + radio-wave template, distinct from the system microphone.
    private func menuBarImage() -> NSImage? {
        if let image = NSImage(named: "MenuBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "MiVoice"
        )
        fallback?.isTemplate = true
        return fallback
    }
}

@main
enum MiVoiceMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
