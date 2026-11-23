import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "MiVoice"
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MiVoice")
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
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        let symbol: String
        if model.isRecording {
            symbol = "waveform"
        } else {
            switch model.linkState {
            case .ready:
                symbol = "mic.fill"
            case .failed, .unauthorized, .bluetoothOff:
                symbol = "mic.slash"
            default:
                symbol = "mic"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MiVoice")
        image?.isTemplate = true
        statusItem.button?.image = image
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
