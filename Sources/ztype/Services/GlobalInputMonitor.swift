import AppKit
import ApplicationServices
import OSLog

@MainActor
final class GlobalInputMonitor {
    nonisolated static let syntheticMarker: Int64 = 0x4E455854
    var onTyping: (() -> Void)?
    var onNativeTab: (() -> Void)?
    var onInvalidate: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onAccept: ((Bool) -> Bool)?
    var acceptanceKeyReleased: Bool { router.acceptanceKeyReleased }
    private var tap: KeyboardEventTap?
    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?
    private var notifications = AccessibilityNotificationLedger<AXUIElement>(equal: { CFEqual($0, $1) })
    private let recovery = AccessibilityObservationRecovery()
    private var needsObservationRecovery = false
    private var observationEpoch = 0
    private let context = AccessibilityContext()
    private lazy var router = KeyboardEventRouter(ownPID: ProcessInfo.processInfo.processIdentifier) { [weak self] action in
        DispatchQueue.main.async { self?.handle(action) }
    }
    private let logger = Logger(subsystem: "app.ztype.mac", category: "Acceptance")
    private let observationLogger = Logger(subsystem: "app.ztype.mac", category: "Compatibility")
    private var startupStatus = KeyboardMonitoringStatus.inactive
    var keyboardStatus: KeyboardMonitoringStatus {
        tap == nil ? startupStatus : KeyboardMonitoringStatus.current()
    }

    func start() -> Bool {
        if tap != nil {
            if keyboardStatus == .ready { return true }
            stop()
        }
        let tap = KeyboardEventTap(router: router)
        guard tap.start() else {
            startupStatus = tap.startupStatus
            logger.error("Keyboard event tap rejected: \(String(describing: self.startupStatus), privacy: .public)")
            return false
        }
        startupStatus = .ready
        self.tap = tap
        logger.info("Keyboard event tap ready with complete event mask")
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onInvalidate?()
                self?.observeFrontmost()
            }
        }
        observeFrontmost()
        return true
    }

    func stop() {
        tap?.stop()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        removeObserver()
        router.reset()
        tap = nil; activation = nil
        startupStatus = .inactive
    }

    func armAcceptance(pid: pid_t?) { router.arm(pid: pid) }
    func isAcceptanceArmed(pid: pid_t) -> Bool { router.isArmed(pid: pid) }

    func observe(_ snapshot: TextFieldSnapshot) {
        if observer == nil { observeFrontmost() }
        guard let observedApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(observedApp, &pid) == .success, pid == snapshot.pid else { return }
        if let observedElement, CFEqual(observedElement, snapshot.element), !needsObservationRecovery { return }
        let focusReady = register(kAXFocusedUIElementChangedNotification, on: observedApp)
        let fieldReady = observeField(snapshot.element)
        needsObservationRecovery = !focusReady || !fieldReady
        if needsObservationRecovery { requestObservationRecovery() }
        else { recovery.cancel() }
    }

    private func handle(_ action: KeyboardEventRouter.Action) {
        switch action {
        case .disabled:
            recovery.cancel()
            logger.error("Event tap disabled; cancelling acceptance")
            onInvalidate?()
        case .accept(let full, let epoch):
            guard router.isCurrent(epoch), keyboardStatus == .ready else { return }
            logger.info("Tab claimed for an owned candidate")
            if onAccept?(full) != true { router.arm(pid: nil) }
        case .nativeTab:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            logger.info("Native Tab passed through: no owned candidate")
            onNativeTab?()
            needsObservationRecovery = true
            requestObservationRecovery()
        case .invalidate:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            onInvalidate?()
            needsObservationRecovery = true
            requestObservationRecovery()
        case .typing:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            onInvalidate?()
            onTyping?()
            if needsObservationRecovery { requestObservationRecovery() }
        }
    }

    private func observeFrontmost() {
        removeObserver()
        needsObservationRecovery = !refreshObservation()
        if needsObservationRecovery { requestObservationRecovery() }
    }

    private func refreshObservation() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return true }
        if observer != nil, let observedApp {
            let registered = register(kAXFocusedUIElementChangedNotification, on: observedApp)
            let fieldReady = observeField()
            return registered && fieldReady
        }
        var newObserver: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { sender, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<GlobalInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            guard let active = monitor.observer, CFEqual(sender, active) else { return }
            if notification as String == kAXFocusedUIElementChangedNotification {
                monitor.needsObservationRecovery = !monitor.observeField()
                if monitor.needsObservationRecovery { monitor.requestObservationRecovery() }
                // Editors may publish a focus echo while pasting into the same text field.
                monitor.onTextChange?()
            } else if notification as String == kAXMovedNotification ||
                      notification as String == kAXResizedNotification {
                monitor.onInvalidate?()
            } else {
                monitor.onTextChange?()
            }
        }, &newObserver)
        guard result == .success, let newObserver else {
            observationLogger.debug("AX observer unavailable: \(result.rawValue)")
            return false
        }
        observer = newObserver
        observedApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(observedApp!, 0.06)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        let registered = register(kAXFocusedUIElementChangedNotification, on: observedApp!)
        let fieldReady = observeField()
        return registered && fieldReady
    }

    private func observeField() -> Bool {
        guard let observedApp,
              let focus = context.elementAttribute(observedApp, kAXFocusedUIElementAttribute),
              let field = context.resolveField(focus) else { removeFieldNotifications(); return false }
        return observeField(field)
    }

    private func removeFieldNotifications() {
        if let observedWindow { removeNotifications(from: observedWindow) }
        observedWindow = nil
        if let observedElement { removeNotifications(from: observedElement) }
        observedElement = nil
    }

    private func observeField(_ field: AXUIElement) -> Bool {
        if let previous = observedElement, !CFEqual(previous, field) { removeFieldNotifications() }
        guard observer != nil else { return false }
        observedElement = field
        var ready = true
        if let window = context.elementAttribute(field, kAXWindowAttribute) {
            if let previous = observedWindow, !CFEqual(previous, window) { removeNotifications(from: previous) }
            observedWindow = window
            for key in [kAXMovedNotification, kAXResizedNotification] {
                if !register(key, on: window) { ready = false }
            }
        } else if let previous = observedWindow {
            removeNotifications(from: previous)
            observedWindow = nil
        }
        for key in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            if !register(key, on: field) { ready = false }
        }
        return ready
    }

    private func register(_ name: String, on element: AXUIElement) -> Bool {
        guard let observer else { return false }
        let result = notifications.register(name, on: element) {
            AXObserverAddNotification(observer, element, name as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        if result != .registered {
            observationLogger.debug("AX notification \(name, privacy: .public): \(String(describing: result), privacy: .public)")
        }
        return result != .retry
    }

    private func removeNotifications(from element: AXUIElement? = nil) {
        notifications.remove(from: element) { [observer] element, name in
            if let observer { AXObserverRemoveNotification(observer, element, name as CFString) }
        }
    }

    private func requestObservationRecovery() {
        guard tap != nil, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let observedApp {
            var attachedPID: pid_t = 0
            if AXUIElementGetPid(observedApp, &attachedPID) != .success || attachedPID != pid {
                observeFrontmost()
                return
            }
        }
        let epoch = observationEpoch
        recovery.request(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.tap != nil && self.observationEpoch == epoch &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }, repair: { [weak self] in
            guard let self else { return true }
            let ready = self.refreshObservation()
            self.needsObservationRecovery = !ready
            if ready {
                self.observationLogger.debug("AX observation recovered after an input or focus event")
                self.onTextChange?()
            }
            return ready
        })
    }

    private func removeObserver() {
        observationEpoch += 1
        recovery.cancel()
        removeNotifications()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; observedElement = nil; observedApp = nil; observedWindow = nil
        needsObservationRecovery = false
    }
}
