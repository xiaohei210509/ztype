import AppKit

final class KeyboardEventRouter: @unchecked Sendable {
    enum Action: Sendable {
        case accept(full: Bool, epoch: UInt64), typing, invalidate, nativeTab, disabled
    }

    private let lock = NSLock()
    private var gate = TabAcceptanceGate()
    private var targetPID: pid_t?
    private var released = true
    private var epoch: UInt64 = 0
    private let ownPID: pid_t
    private let send: @Sendable (Action) -> Void

    init(ownPID: pid_t, send: @escaping @Sendable (Action) -> Void) {
        self.ownPID = ownPID
        self.send = send
    }

    var acceptanceKeyReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    func arm(pid: pid_t?) {
        lock.lock()
        targetPID = pid
        lock.unlock()
    }

    func isArmed(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return targetPID == pid
    }

    func isCurrent(_ requestedEpoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epoch == requestedEpoch && targetPID != nil
    }

    func reset() {
        lock.lock()
        gate.reset()
        targetPID = nil
        released = true
        epoch &+= 1
        lock.unlock()
    }

    func handle(type: CGEventType, key: Int64, modifiers: CGEventFlags,
                repeating: Bool, eventPID: pid_t) -> Bool {
        var action: Action?
        lock.lock()
        let consumed: Bool
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gate.reset()
            targetPID = nil
            released = true
            epoch &+= 1
            action = .disabled
            consumed = false
        } else if type == .flagsChanged {
            released = !gate.isClaimed && modifiers.isEmpty
            consumed = false
        } else if type == .keyUp {
            consumed = gate.consume(type: type, key: key, modifiers: modifiers,
                                    repeating: false, accept: { false })
            if consumed { released = modifiers.isEmpty }
        } else if eventPID == ownPID {
            consumed = false
        } else if type == .keyDown {
            let eligible = targetPID != nil && (eventPID == 0 || eventPID == targetPID)
            let wasClaimed = gate.isClaimed
            consumed = gate.consume(type: type, key: key, modifiers: modifiers,
                                    repeating: repeating, accept: { eligible })
            if consumed {
                released = false
                if !wasClaimed { action = .accept(full: modifiers == .maskAlternate, epoch: epoch) }
            } else {
                targetPID = nil
                epoch &+= 1
                if !modifiers.contains(.maskCommand), !modifiers.contains(.maskControl),
                   ![48, 53, 123, 124, 125, 126].contains(key) {
                    action = .typing
                } else { action = key == 48 && modifiers.isEmpty ? .nativeTab : .invalidate }
            }
        } else {
            targetPID = nil
            epoch &+= 1
            action = .invalidate
            consumed = false
        }
        lock.unlock()
        if let action { send(action) }
        return consumed
    }
}

final class KeyboardEventTap: @unchecked Sendable {
    private let router: KeyboardEventRouter
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false
    private(set) var startupStatus = KeyboardMonitoringStatus.inactive

    init(router: KeyboardEventRouter) { self.router = router }

    func start() -> Bool {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: KeyboardMonitoringStatus.requiredMask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<KeyboardEventTap>.fromOpaque(pointer).takeUnretainedValue()
                if event.getIntegerValueField(.eventSourceUserData) == GlobalInputMonitor.syntheticMarker {
                    return Unmanaged.passUnretained(event)
                }
                let consumed = owner.router.handle(
                    type: type, key: event.getIntegerValueField(.keyboardEventKeycode),
                    modifiers: event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]),
                    repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    eventPID: pid_t(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
                )
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.reenable()
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { startupStatus = .unavailable; return false }
        // A nonnil tap can have keyDown/keyUp silently removed by the permission service.
        CGEvent.tapEnable(tap: port, enable: true)
        startupStatus = KeyboardMonitoringStatus.current()
        guard startupStatus == .ready else {
            CFMachPortInvalidate(port)
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            startupStatus = .unavailable
            CFMachPortInvalidate(port)
            return false
        }
        lock.lock()
        tap = port
        lock.unlock()
        let worker = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.unlock()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            lock.lock()
            runLoop = nil
            lock.unlock()
        }
        worker.name = "ztype.keyboard"
        worker.qualityOfService = .userInteractive
        worker.start()
        return true
    }

    func stop() {
        lock.lock()
        stopped = true
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        lock.unlock()
        router.reset()
    }

    private func reenable() {
        lock.lock()
        if !stopped, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        lock.unlock()
    }
}
