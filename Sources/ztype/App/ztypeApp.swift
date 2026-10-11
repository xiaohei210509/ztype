import SwiftUI
import AppKit
import Darwin

@main
struct ztypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ztype", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 760, height: 600)
        .commands {
            CompletionCommands(model: delegate.model)
        }
        Settings { SettingsView(model: delegate.model) }
        MenuBarExtra("ztype", systemImage: "text.cursor") {
            StatusMenu(model: delegate.model)
        }
    }
}

private struct CompletionCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("启用补全", isOn: $model.enabled)
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("打开 ztype") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Toggle("启用补全", isOn: $model.enabled)
        Button(model.globalEnabled ? "关闭跨应用" : "开启跨应用") {
            model.globalEnabled ? model.stopGlobal() : model.startGlobal()
        }
        Button("卸载模型") { model.sleepModel() }
        Button("设置…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 ztype") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep the model alive even when every SwiftUI window is closed.
    let model = AppModel()
    private var terminationSources: [DispatchSourceSignal] = []
    private var terminationTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshPermissions()
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                self?.model.shutdown()
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSources.append(source)
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shutdown()
        guard model.needsClipboardRecovery else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.model.finishShutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        model.finishShutdown()
    }
}
