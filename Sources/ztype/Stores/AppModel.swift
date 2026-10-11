import AppKit
import SwiftUI
import Carbon
import OSLog
import ztypeCore

enum EnergyMode: String, CaseIterable, Identifiable {
    case fast, balanced, eco
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: return "响应优先"; case .balanced: return "均衡"; case .eco: return "节能" }
    }
    var delay: Double {
        switch self { case .fast: return 0.16; case .balanced: return 0.26; case .eco: return 0.48 }
    }
    var minimumInterval: Double {
        switch self { case .fast: return 0.3; case .balanced: return 0.5; case .eco: return 0.9 }
    }
    var tokens: Int { self == .eco ? 12 : 16 }
}

struct LocalSnapshot {
    let context: CompletionContext
    let range: NSRange
    let caret: CGRect
}

@MainActor
struct GlobalAcceptanceIO {
    let frontmostPID: () -> pid_t?
    let captureText: () -> TextFieldSnapshot?
    let submit: (String, TextFieldSnapshot) -> TextSubmission?
    let keyReleased: () -> Bool
    let captureField: () -> FieldSnapshot?
    let presentCandidate: (String, FieldSnapshot) -> Bool
    let keyboardReady: () -> Bool

    init(frontmostPID: @escaping () -> pid_t?, captureText: @escaping () -> TextFieldSnapshot?,
         submit: @escaping (String, TextFieldSnapshot) -> TextSubmission?,
         keyReleased: @escaping () -> Bool = { true },
         captureField: @escaping () -> FieldSnapshot? = { nil },
         presentCandidate: @escaping (String, FieldSnapshot) -> Bool = { _, _ in true },
         keyboardReady: @escaping () -> Bool = { true }) {
        self.frontmostPID = frontmostPID
        self.captureText = captureText
        self.submit = submit
        self.keyReleased = keyReleased
        self.captureField = captureField
        self.presentCandidate = presentCandidate
        self.keyboardReady = keyboardReady
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var enabled = true {
        didSet {
            invalidate()
            if !enabled { engine.stop() }
        }
    }
    @Published var globalEnabled = false
    @Published var engineState = "按需加载 · 本地推理"
    @Published var status = "就绪"
    @Published var permission = AccessibilityContext.trusted
    @Published var inputPermission = CGPreflightListenEventAccess()
    @Published var keyboardMonitoring = KeyboardMonitoringStatus.inactive
    @Published var suggestion = ""
    @Published var generated = 0
    @Published var accepted = 0
    @Published var rejected = 0
    @Published var latency: Double = 0
    @Published var p95: Double = 0
    @Published var mode: EnergyMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "energyMode")
            invalidate()
            engine.rest(after: effectiveMode == .eco ? 30 : 90)
        }
    }
    @Published var excludedText: String {
        didSet { UserDefaults.standard.set(excludedText, forKey: "excludedApps"); refreshExclusions(); invalidate() }
    }
    var localCapture: (() -> LocalSnapshot?)?
    var localInsert: ((String, NSRange) -> Bool)?
    private let engine = EngineProcess()
    private let monitor = GlobalInputMonitor()
    private let accessibility = AccessibilityContext()
    private let panel = SuggestionPanel()
    private var task: Task<Void, Never>?
    private var revision = 0
    private(set) var predictionScheduleCount = 0
    private var globalSnapshot: TextFieldSnapshot?
    private var localSnapshot: LocalSnapshot?
    private var displayedAt: ContinuousClock.Instant?
    private var lastRequest = ContinuousClock.now - .seconds(10)
    private var timings: [Double] = []
    private var observers: [NSObjectProtocol] = []
    private var blockedAt: ContinuousClock.Instant?
    private var acceptanceTask: Task<Void, Never>?
    private var pendingAcceptancePID: pid_t?
    private var acceptanceRequests: [Bool] = []
    private let acceptanceIO: GlobalAcceptanceIO
    private var textNotificationTask: Task<Void, Never>?
    private let acceptanceLogger = Logger(subsystem: "app.ztype.mac", category: "Acceptance")
    private var globalRequested = UserDefaults.standard.bool(forKey: "globalMonitoringRequested")
    private var tabOnlyInput = false

    init(acceptanceIO: GlobalAcceptanceIO? = nil) {
        let accessibility = self.accessibility
        let monitor = self.monitor
        let panel = self.panel
        self.acceptanceIO = acceptanceIO ?? GlobalAcceptanceIO(
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            captureText: { accessibility.captureText() },
            submit: { text, snapshot in
                accessibility.submit(text, into: snapshot, canSubmit: {
                    monitor.isAcceptanceArmed(pid: snapshot.pid) && monitor.keyboardStatus == .ready
                })
            },
            keyReleased: { monitor.acceptanceKeyReleased },
            captureField: { accessibility.capture() },
            presentCandidate: { panel.show($0, field: $1) },
            keyboardReady: { monitor.keyboardStatus == .ready }
        )
        mode = EnergyMode(rawValue: UserDefaults.standard.string(forKey: "energyMode") ?? "") ?? .balanced
        excludedText = UserDefaults.standard.string(forKey: "excludedApps") ?? ""
        engine.onState = { [weak self] state in self?.engineState = state }
        monitor.onInvalidate = { [weak self] in self?.invalidate() }
        monitor.onTyping = { [weak self] in self?.schedule(global: true) }
        monitor.onNativeTab = { [weak self] in self?.nativeTab() }
        monitor.onTextChange = { [weak self] in self?.globalTextChanged() }
        monitor.onAccept = { [weak self] full in self?.accept(full: full, global: true) ?? false }
        refreshExclusions()
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate(); self?.engine.stop() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.thermalState == .serious ||
                    ProcessInfo.processInfo.thermalState == .critical {
                    self?.invalidate(); self?.engine.stop(); self?.status = "温度较高 · 已暂停"
                }
            }
        })
    }

    var effectiveMode: EnergyMode {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .eco : mode
    }

    var localSuggestion: String { localSnapshot == nil ? "" : suggestion }

    func startGlobal() {
        globalRequested = true
        UserDefaults.standard.set(true, forKey: "globalMonitoringRequested")
        configureGlobal(prompt: true)
    }

    func refreshPermissions() {
        permission = AccessibilityContext.trusted
        inputPermission = CGPreflightListenEventAccess()
        guard globalRequested else { return }
        configureGlobal(prompt: false)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoringSettings() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func configureGlobal(prompt: Bool) {
        permission = AccessibilityContext.trusted
        inputPermission = CGPreflightListenEventAccess()
        guard permission else {
            monitor.stop()
            globalEnabled = false
            keyboardMonitoring = .inactive
            invalidate()
            status = "需要辅助功能权限"
            if prompt {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                openAccessibilitySettings()
            }
            return
        }
        globalEnabled = monitor.start()
        keyboardMonitoring = monitor.keyboardStatus
        status = globalEnabled ? "跨应用补全已开启" : "键盘监听不可用 · 请检查当前版本的输入监控授权"
        if !globalEnabled {
            invalidate()
            engine.rest(after: 1)
            if prompt, !inputPermission { openInputMonitoringSettings() }
        }
    }

    func stopGlobal() {
        globalRequested = false
        UserDefaults.standard.set(false, forKey: "globalMonitoringRequested")
        globalEnabled = false
        monitor.stop()
        keyboardMonitoring = .inactive
        invalidate()
        engine.rest(after: 1)
        status = "跨应用补全已关闭"
    }

    func localChanged() {
        guard !tabOnlyInput else { return }
        if localContextIsUnchanged { return }
        invalidate()
        schedule(global: false)
    }

    func localSelectionChanged() {
        guard localSnapshot != nil else { return }
        if !localContextIsUnchanged { invalidate() }
    }

    private var localContextIsUnchanged: Bool {
        guard let snapshot = localSnapshot, let current = localCapture?() else { return false }
        return snapshot.context == current.context && snapshot.range == current.range
    }

    func invalidate(preserveAcceptance: Bool = false) {
        tabOnlyInput = false
        if !preserveAcceptance { monitor.armAcceptance(pid: nil) }
        revision += 1
        task?.cancel()
        task = nil
        textNotificationTask?.cancel()
        textNotificationTask = nil
        acceptanceTask?.cancel()
        acceptanceTask = nil
        pendingAcceptancePID = nil
        acceptanceRequests.removeAll()
        suggestion = ""
        globalSnapshot = nil
        localSnapshot = nil
        displayedAt = nil
        panel.hide()
        if status == "候选可用" || status == "预测中" { status = "就绪" }
    }

    func dismiss() {
        blockedAt = .now
        invalidate()
        status = "已忽略"
    }

    func nativeTab() {
        invalidate()
        tabOnlyInput = true
    }

    func schedule(global: Bool) {
        guard enabled, !tabOnlyInput, !global || globalEnabled else { return }
        // Accepted text remains the notification baseline even after all words are consumed.
        guard global ? globalSnapshot == nil && pendingAcceptancePID == nil : localSnapshot == nil else { return }
        if let blockedAt, blockedAt.duration(to: .now) < .seconds(1) { return }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { return }
        predictionScheduleCount += 1
        let generation = revision
        let currentMode = effectiveMode
        let elapsed = lastRequest.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let delay = max(currentMode.delay, currentMode.minimumInterval - elapsedSeconds)
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engine.rest(after: self.effectiveMode == .eco ? 30 : 90) }
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                let capturePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                var field = global ? self.accessibility.capture() : nil
                if global, field == nil, self.accessibility.failure?.mayBeLayoutDelay == true {
                    // One cancellation-aware settling retry, not background polling.
                    try await Task.sleep(for: .milliseconds(120))
                    try Task.checkCancellation()
                    guard generation == self.revision,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == capturePID else { return }
                    field = self.accessibility.capture()
                }
                let local = global ? nil : self.localCapture?()
                guard let context = field?.context ?? local?.context else {
                    if generation == self.revision {
                        if global {
                            let reason = self.accessibility.failure?.message ?? "无法读取输入框"
                            let app = self.accessibility.applicationName
                            self.status = app.isEmpty ? reason : "\(app) · \(reason)"
                        } else { self.status = "等待试写框的已提交文字" }
                    }
                    return
                }
                guard context.eligible else {
                    if generation == self.revision { self.status = "上下文不足或当前位置不适合补全" }
                    return
                }
                let client = try await self.engine.ready()
                try Task.checkCancellation()
                guard generation == self.revision else { return }
                self.lastRequest = .now
                self.status = "预测中"
                let result = try await client.complete(context, tokens: currentMode.tokens)
                try Task.checkCancellation()
                guard generation == self.revision else { return }
                if global {
                    guard let field, let fresh = self.accessibility.capture() else {
                        self.status = self.accessibility.failure?.message ?? "无法重新读取输入框"
                        return
                    }
                    guard field.matches(fresh) else { self.status = "上下文已变化 · 已丢弃"; return }
                } else {
                    guard let local, let fresh = self.localCapture?(),
                          fresh.context == local.context, fresh.range == local.range else { return }
                }
                self.generated += 1
                self.latency = result.milliseconds
                self.timings.append(result.milliseconds)
                if self.timings.count > 100 { self.timings.removeFirst() }
                let sorted = self.timings.sorted()
                self.p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                guard let suggestion = CompletionPolicy.filter(result.text, context: context) else {
                    self.rejected += 1
                    self.status = "候选已过滤"
                    return
                }
                if global, !self.acceptanceIO.keyboardReady() {
                    self.suspendIncompleteMonitoring()
                    return
                }
                if let field, !self.panel.show(suggestion, field: field) {
                    self.status = "等待可用行内位置"
                    return
                }
                if let field { self.recordGlobalCandidate(suggestion, field: field) }
                else if let local { self.recordLocalCandidate(suggestion, snapshot: local) }
            } catch is CancellationError {
            } catch {
                if generation == self.revision {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func accept(full: Bool, global: Bool) -> Bool {
        if global { return reserveGlobalAcceptance(full: full) }
        guard enabled, !suggestion.isEmpty, displayedAt != nil else { invalidate(); return false }
        let original = suggestion
        let text = full ? suggestion : CompletionPolicy.nextWord(in: suggestion)
        guard let snapshot = localSnapshot, let fresh = localCapture?(),
              snapshot.context == fresh.context, snapshot.range == fresh.range,
              localInsert?(text, snapshot.range) == true else { invalidate(); return false }
        guard let current = localCapture?(), TextInsertion.confirm(
            before: snapshot.context.before, after: snapshot.context.after,
            location: snapshot.range.location, text: text,
            currentBefore: current.context.before, currentAfter: current.context.after,
            currentLocation: current.range.location, currentSelectionLength: current.range.length
        ) == .confirmed else {
            invalidate()
            status = "未能确认候选插入 · 已停止接受"
            return true
        }
        accepted += 1
        invalidate()
        localSnapshot = current
        status = "已接受"
        let remainder = String(original.dropFirst(text.count))
        if !full, !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
            recordLocalCandidate(remainder, snapshot: current)
        }
        return true
    }

    func recordLocalCandidate(_ text: String, snapshot: LocalSnapshot) {
        suggestion = text
        localSnapshot = snapshot
        displayedAt = .now
        status = "候选可用"
    }

    private func reserveGlobalAcceptance(full: Bool) -> Bool {
        guard acceptanceIO.keyboardReady() else { suspendIncompleteMonitoring(); return false }
        let pid = acceptanceIO.frontmostPID()
        if let pendingAcceptancePID {
            guard pid == pendingAcceptancePID else { return false }
            if acceptanceRequests.count < 16 { acceptanceRequests.append(full) }
            return true
        }
        guard enabled, globalEnabled, !suggestion.isEmpty, displayedAt != nil,
              let snapshot = globalSnapshot, pid == snapshot.pid else { return false }
        let original = suggestion
        let text = full ? original : CompletionPolicy.nextWord(in: original)
        guard !text.isEmpty else { return false }
        invalidate(preserveAcceptance: true)
        globalSnapshot = snapshot
        suggestion = original
        let generation = revision
        pendingAcceptancePID = snapshot.pid
        acceptanceRequests = [full]
        status = "正在接受候选"
        // No AX calls or text writes inside the event-tap callback.
        acceptanceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == self.revision, !Task.isCancelled else { return }
            defer {
                if generation == self.revision {
                    self.pendingAcceptancePID = nil
                    self.acceptanceTask = nil
                    self.acceptanceRequests.removeAll()
                    if self.suggestion.isEmpty { self.monitor.armAcceptance(pid: nil) }
                }
            }
            var remaining = original
            var state = snapshot
            while !remaining.isEmpty {
                if !self.acceptanceRequests.isEmpty {
                    let releaseDeadline = ContinuousClock.now + .seconds(5)
                    while !self.acceptanceIO.keyReleased() {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                        guard generation == self.revision, !Task.isCancelled else { return }
                        if ContinuousClock.now > releaseDeadline {
                            self.status = "接受按键尚未松开 · 已取消"
                            self.invalidate()
                            return
                        }
                    }
                    guard generation == self.revision, !Task.isCancelled else { return }
                    guard self.acceptanceIO.frontmostPID() == state.pid else { self.invalidate(); return }
                    let takeAll = self.acceptanceRequests.removeFirst()
                    let part = takeAll ? remaining : CompletionPolicy.nextWord(in: remaining)
                    guard let current = await self.insertAndConfirm(part, into: state, generation: generation) else {
                        if generation == self.revision { self.invalidate() }
                        return
                    }
                    state = current
                    remaining = String(remaining.dropFirst(part.count))
                    if remaining.trimmingCharacters(in: .whitespaces).isEmpty { remaining = "" }
                    self.globalSnapshot = current
                    self.suggestion = remaining
                    self.displayedAt = remaining.isEmpty ? nil : .now
                    continue
                }
                // AX layout can lag behind a confirmed text change; do not discard the remainder.
                for delay in [0, 20, 40, 80, 120] {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard generation == self.revision, !Task.isCancelled else { return }
                    if !self.acceptanceRequests.isEmpty { break }
                    if self.presentGlobalRemainder() { return }
                }
                if !self.acceptanceRequests.isEmpty { continue }
                self.status = "候选已保留 · 等待行内位置"
                self.acceptanceLogger.info("Owned candidate retained while layout is unavailable")
                return
            }
            self.status = "已接受"
            self.acceptanceLogger.info("Owned candidate consumed; waiting for a new edit")
        }
        return true
    }

    private func insertAndConfirm(_ text: String, into snapshot: TextFieldSnapshot,
                                  generation: Int) async -> TextFieldSnapshot? {
        guard acceptanceIO.keyboardReady() else { suspendIncompleteMonitoring(); return nil }
        guard let submission = acceptanceIO.submit(text, snapshot) else {
            status = "未能完成候选插入 · 已停止重试"
            acceptanceLogger.notice("Acceptance cancelled before submission")
            return nil
        }
        var confirmed = false
        defer { submission.finish(confirmed) }
        for delay in [10, 20, 40, 80, 120, 180, 240] {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return nil }
            guard generation == revision, !Task.isCancelled else { return nil }
            guard acceptanceIO.frontmostPID() == snapshot.pid else { return nil }
            guard let current = acceptanceIO.captureText() else { continue }
            guard snapshot.sameTarget(current) else {
                status = "输入位置已变化 · 已停止接受"
                acceptanceLogger.notice("Acceptance target changed")
                return nil
            }
            switch TextInsertion.confirm(
                before: snapshot.context.before, after: snapshot.context.after,
                location: snapshot.range.location, text: text,
                currentBefore: current.context.before, currentAfter: current.context.after,
                currentLocation: current.range.location, currentSelectionLength: current.range.length
            ) {
            case .unchanged: continue
            case .diverged:
                status = "文本已变化 · 不再重复插入"
                acceptanceLogger.notice("Acceptance receipt diverged")
                return nil
            case .confirmed:
                confirmed = true
                accepted += 1
                acceptanceLogger.info("Acceptance confirmed")
                return current
            }
        }
        status = "未能确认候选插入 · 不再重复发送"
        acceptanceLogger.notice("Acceptance receipt timed out")
        return nil
    }

    func recordGlobalCandidate(_ text: String, field: FieldSnapshot) {
        guard acceptanceIO.keyboardReady() else { suspendIncompleteMonitoring(); return }
        acceptanceLogger.info("Owned candidate published")
        suggestion = text
        globalSnapshot = field.textState
        monitor.armAcceptance(pid: field.pid)
        localSnapshot = nil
        displayedAt = .now
        status = "候选可用"
    }

    @discardableResult
    private func presentGlobalRemainder() -> Bool {
        guard let snapshot = globalSnapshot, !suggestion.isEmpty,
              let field = acceptanceIO.captureField(), snapshot.matches(field.textState),
              acceptanceIO.presentCandidate(suggestion, field) else { return false }
        status = "候选可用"
        acceptanceLogger.info("Owned candidate continued without prediction")
        return true
    }

    private func suspendIncompleteMonitoring() {
        keyboardMonitoring = monitor.keyboardStatus
        monitor.stop()
        globalEnabled = false
        invalidate()
        engine.rest(after: 1)
        status = "键盘监听已失效 · 已暂停跨应用补全"
    }

    func globalTextChanged() {
        guard pendingAcceptancePID == nil, !tabOnlyInput else { return }
        guard let displayed = globalSnapshot else {
            invalidate()
            schedule(global: true)
            return
        }
        textNotificationTask?.cancel()
        let generation = revision
        textNotificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [30, 40, 80, 120] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard generation == self.revision, self.pendingAcceptancePID == nil else { return }
                guard self.acceptanceIO.frontmostPID() == displayed.pid else { self.invalidate(); return }
                guard let current = self.acceptanceIO.captureText() else { continue }
                guard displayed.sameTarget(current) else { self.invalidate(); return }
                if displayed.matches(current) {
                    // Our text/focus echoes can restore layout, but never replace the cached words.
                    self.presentGlobalRemainder()
                    return
                }
                self.invalidate()
                self.schedule(global: true)
                return
            }
            if !self.suggestion.isEmpty { self.status = "候选已保留 · 等待上下文恢复" }
        }
    }

    func sleepModel() {
        invalidate()
        engine.stop()
        engineState = "模型已卸载"
    }

    func shutdown() {
        invalidate()
        monitor.stop()
        engine.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }

    var needsClipboardRecovery: Bool { accessibility.hasActiveInsertion }
    func finishShutdown() { accessibility.finishShutdown() }

    private func refreshExclusions() {
        let additions = excludedText.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        accessibility.excluded = Set([
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.agilebits.onepassword7", "com.1password.1password", "com.apple.keychainaccess"
        ] + additions)
    }
}
