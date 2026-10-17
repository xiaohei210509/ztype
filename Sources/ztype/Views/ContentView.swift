import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "text.cursor").font(.system(size: 26)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ztype").font(.title2.bold())
                    Text(model.engineState).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("补全", isOn: $model.enabled).toggleStyle(.switch).fixedSize()
            }
            .padding(24)
            Divider()
            HStack {
                Label("试写", systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Circle().fill(model.suggestion.isEmpty ? Color.secondary : .teal).frame(width: 7, height: 7)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            TrialEditor(model: model)
                .frame(minHeight: 210)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .padding(.horizontal, 24)
            HStack(spacing: 18) {
                metric("上次展示", value: model.latency == 0 ? "—" : String(format: "%.0f ms", model.latency))
                    .help(String(format: "含等待、读取、模型加载及推理；其中推理 %.0f ms", model.inferenceLatency))
                Divider().frame(height: 28)
                metric("P95 展示", value: model.p95 == 0 ? "—" : String(format: "%.0f ms", model.p95))
                Divider().frame(height: 28)
                metric("已接受", value: "\(model.accepted)")
                Divider().frame(height: 28)
                metric("已过滤", value: "\(model.rejected)")
                Spacer()
                Button { model.sleepModel() } label: { Image(systemName: "moon.zzz") }
                    .help("卸载本地模型")
                    .buttonStyle(.borderless)
            }
            .padding(24)
            Divider()
            HStack(spacing: 16) {
                Label("跨应用", systemImage: "macwindow.on.rectangle").font(.headline)
                Spacer()
                Text(model.globalEnabled ? "已开启" : "未开启")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.globalEnabled ? "关闭" : "开启") {
                    model.globalEnabled ? model.stopGlobal() : model.startGlobal()
                }
                .buttonStyle(.borderedProminent).tint(.teal)
            }
            .padding(24)
        }
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItem { SettingsLink { Image(systemName: "gearshape") }.help("设置") }
        }
    }

    private func metric(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.body, design: .monospaced)).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}
