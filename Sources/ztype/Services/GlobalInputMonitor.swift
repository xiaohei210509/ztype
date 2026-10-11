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
    private let context = AccessibilityContext()
    private lazy var router = KeyboardEventRouter(ownPID: ProcessInfo.processInfo.processIdentifier) { [weak self] action in
        DispatchQueue.main.async { self?.handle(action) }
    }
    private let logger = Logger(subsystem: "app.ztype.mac", category: "Acceptance")
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

    private func handle(_ action: KeyboardEventRouter.Action) {
        switch action {
        case .disabled:
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
        case .invalidate:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            onInvalidate?()
        case .typing:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            onInvalidate?()
            onTyping?()
        }
    }

    private func observeFrontmost() {
        removeObserver()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        var newObserver: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<GlobalInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXFocusedUIElementChangedNotification {
                monitor.observeField()
                // Editors may publish a focus echo while pasting into the same text field.
                monitor.onTextChange?()
            } else if notification as String == kAXMovedNotification ||
                      notification as String == kAXResizedNotification {
                monitor.onInvalidate?()
            } else {
                monitor.onTextChange?()
            }
        }, &newObserver) == .success, let newObserver else { return }
        observer = newObserver
        observedApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(observedApp!, 0.06)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        AXObserverAddNotification(newObserver, observedApp!, kAXFocusedUIElementChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        observeField()
    }

    private func observeField() {
        if let observer, let observedWindow {
            for key in [kAXMovedNotification, kAXResizedNotification] {
                AXObserverRemoveNotification(observer, observedWindow, key as CFString)
            }
        }
        observedWindow = nil
        if let observer, let observedElement {
            for key in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                AXObserverRemoveNotification(observer, observedElement, key as CFString)
            }
        }
        observedElement = nil
        guard let observer, let observedApp,
              let focus = context.elementAttribute(observedApp, kAXFocusedUIElementAttribute),
              let field = context.resolveField(focus) else { return }
        observedElement = field
        if let window = context.elementAttribute(field, kAXWindowAttribute) {
            observedWindow = window
            for key in [kAXMovedNotification, kAXResizedNotification] {
                AXObserverAddNotification(observer, window, key as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
        }
        for key in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, field, key as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; observedElement = nil; observedApp = nil; observedWindow = nil
    }
}
