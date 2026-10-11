import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("推理") {
                Picker("资源策略", selection: $model.mode) {
                    ForEach(EnergyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                LabeledContent("模型", value: "Qwen3 1.7B · Q8_0")
                LabeledContent("推理位置", value: "本机 · Metal")
                LabeledContent("空闲卸载", value: model.effectiveMode == .eco ? "30 秒" : "90 秒")
                LabeledContent("低电量模式", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "节能" : "跟随所选策略")
            }
            Section("权限") {
                LabeledContent("辅助功能", value: model.permission ? "已授权" : "未授权")
                Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                LabeledContent("输入监控", value: model.inputPermission ? "已授权" : "未对当前版本授权")
                Button("打开输入监控设置") { model.openInputMonitoringSettings() }
                LabeledContent("Tab 接管", value: model.keyboardMonitoring.title)
                Button("重新检查") { model.refreshPermissions() }
            }
            Section("排除应用 Bundle ID") {
                TextEditor(text: $model.excludedText).font(.system(.body, design: .monospaced))
                    .frame(height: 88)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 550)
    }
}
