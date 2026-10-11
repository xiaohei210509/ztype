import AppKit
import ApplicationServices
import Carbon
import OSLog
import ztypeCore

struct TextFieldSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let range: CFRange
    let context: CompletionContext
    let focus: AXUIElement

    func sameTarget(_ other: TextFieldSnapshot) -> Bool {
        pid == other.pid && CFEqual(element, other.element) && CFEqual(focus, other.focus)
    }

    func matches(_ other: TextFieldSnapshot) -> Bool {
        sameTarget(other) && range.location == other.range.location &&
        range.length == other.range.length && context == other.context
    }
}

struct FieldSnapshot {
    let textState: TextFieldSnapshot
    let caret: CGRect
    let visibleBounds: CGRect
    let font: NSFont

    var element: AXUIElement { textState.element }
    var pid: pid_t { textState.pid }
    var range: CFRange { textState.range }
    var context: CompletionContext { textState.context }

    func matches(_ other: FieldSnapshot) -> Bool {
        textState.matches(other.textState) && caret == other.caret && visibleBounds == other.visibleBounds &&
        font == other.font
    }
}

enum ContextCaptureFailure {
    case noPermission, secureInput, composition, noApplication, ownApplication, excluded
    case noField, unsupportedField, secureField, disabledField, noSelection, selectedText
    case noText, noCharacterCount, noCaret, noVisibleBounds, offscreen

    var mayBeLayoutDelay: Bool {
        switch self {
        case .noField, .noSelection, .noText, .noCharacterCount, .noCaret, .noVisibleBounds: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .noPermission: return "需要辅助功能权限"
        case .secureInput: return "安全输入模式 · 已暂停"
        case .composition: return "输入法组合模式 · 已暂停"
        case .noApplication: return "未找到前台应用"
        case .ownApplication: return "等待其他应用的输入框"
        case .excluded: return "当前应用已排除"
        case .noField: return "无法读取聚焦输入框"
        case .unsupportedField: return "当前控件不是支持的输入框"
        case .secureField: return "密码输入框 · 已暂停"
        case .disabledField: return "当前输入框不可编辑"
        case .noSelection: return "当前应用未提供光标范围"
        case .selectedText: return "文字选中时暂停补全"
        case .noText: return "当前应用未提供光标附近文本"
        case .noCharacterCount: return "当前应用未提供有效字符数量"
        case .noCaret: return "当前应用未提供有效光标位置"
        case .noVisibleBounds: return "当前应用未提供输入框可见范围"
        case .offscreen: return "光标不在输入框可见区域"
        }
    }
}

@MainActor
final class AccessibilityContext {
    private var clipboardInsertion: ClipboardInsertion?
    var hasActiveInsertion: Bool { clipboardInsertion?.isActive == true }

    func finishShutdown() { clipboardInsertion?.restore() }
    private let logger = Logger(subsystem: "app.ztype.mac", category: "Acceptance")
    private(set) var failure: ContextCaptureFailure?
    private(set) var applicationName = ""
    var excluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.agilebits.onepassword7", "com.1password.1password",
        "com.apple.keychainaccess"
    ]

    static var trusted: Bool { AXIsProcessTrusted() }

    static var inputLanguage: String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "" }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first ?? ""
    }

    static var compositionInputSource: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        let kind = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return kind as String != kTISTypeKeyboardLayout as String
    }

    func capture() -> FieldSnapshot? {
        guard let state = captureText() else { return nil }
        let reader = textReader(state.element)
        guard let selection = reader.selection(),
              selection.range.location == state.range.location,
              selection.range.length == state.range.length,
              let count = reader.characterCount() else { return fail(.noSelection) }
        let start = max(0, state.range.location - 1800)
        let resolvedCaret = reader.caret(selection, before: state.context.before, after: state.context.after,
                                        start: start, atEnd: state.range.location == count)
        guard let caret = resolvedCaret, InlineGeometry.valid(caret) else { return fail(.noCaret) }
        guard let visibleBounds = visibleBounds(state.element) else { return fail(.noVisibleBounds) }
        guard visibleBounds.contains(CGPoint(x: caret.midX, y: caret.midY)) else { return fail(.offscreen) }
        let font = font(state.element, at: state.range.location, caretHeight: caret.height)
        return FieldSnapshot(textState: state, caret: caret, visibleBounds: visibleBounds, font: font)
    }

    func captureText() -> TextFieldSnapshot? {
        failure = nil
        applicationName = ""
        guard Self.trusted else { return fail(.noPermission) }
        guard !IsSecureEventInputEnabled() else { return fail(.secureInput) }
        guard !Self.compositionInputSource else { return fail(.composition) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return fail(.noApplication) }
        applicationName = app.localizedName ?? app.bundleIdentifier ?? ""
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return fail(.ownApplication) }
        guard !excluded.contains(app.bundleIdentifier ?? "") else { return fail(.excluded) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.06)
        guard let focus = elementAttribute(application, kAXFocusedUIElementAttribute) else { return fail(.noField) }
        guard let element = resolveField(focus) else { return fail(.unsupportedField) }
        AXUIElementSetMessagingTimeout(element, 0.06)
        guard (attribute(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else {
            return fail(.secureField)
        }
        guard (attribute(element, kAXEnabledAttribute) as? Bool) != false else { return fail(.disabledField) }
        let reader = textReader(element)
        guard let selection = reader.selection() else { return fail(.noSelection) }
        let range = selection.range
        guard range.length == 0 else { return fail(.selectedText) }
        let start = max(0, range.location - 1800)
        let beforeRange = CFRange(location: start, length: range.location - start)
        guard let before = reader.text(beforeRange) else { return fail(.noText) }
        guard let count = reader.characterCount(),
              count >= range.location else { return fail(.noCharacterCount) }
        let afterLength = min(320, count - range.location)
        let after: String
        if afterLength > 0 {
            guard let suffix = reader.text(CFRange(location: range.location, length: afterLength)) else {
                return fail(.noText)
            }
            after = suffix
        } else { after = "" }
        guard let freshSelection = reader.selection(),
              range.location == freshSelection.range.location,
              range.length == freshSelection.range.length else { return fail(.noSelection) }
        return TextFieldSnapshot(element: element, pid: app.processIdentifier, range: range,
                                 context: CompletionContext(before: before, after: after,
                                                            application: app.bundleIdentifier ?? "",
                                                            inputLanguage: Self.inputLanguage), focus: focus)
    }

    private func fail<T>(_ reason: ContextCaptureFailure) -> T? {
        failure = reason
        return nil
    }

    private func parameter(_ element: AXUIElement, _ key: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, key as CFString, parameter, &value
        ) == .success else { return nil }
        return value
    }

    private func textReader(_ element: AXUIElement) -> AccessibleTextReader {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        let supported = Set((names as? [String]) ?? [])
        return AccessibleTextReader(attribute: { self.attribute(element, $0) }, parameter: { key, value in
            guard supported.isEmpty || supported.contains(key) else { return nil }
            return self.parameter(element, key, value)
        })
    }

    private func isTextField(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) { return true }
        guard (attribute(element, "AXEditable") as? Bool) == true else { return false }
        return attribute(element, kAXSelectedTextRangeAttribute) != nil ||
            attribute(element, "AXSelectedTextMarkerRange") != nil
    }

    func resolveField(_ focus: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(focus, 0.04)
        if (attribute(focus, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return focus }
        if isTextField(focus) { return focus }
        // Some editors focus a layout/container rather than the editable descendant.
        // Never search an entire window or pick one of several unrelated editors.
        let deadline = ContinuousClock.now + .milliseconds(35)
        var queue: [(AXUIElement, Int)] = [(focus, 0)]
        var visited: [AXUIElement] = []
        var candidates: [AXUIElement] = []
        while !queue.isEmpty, visited.count < 48, ContinuousClock.now < deadline {
            let (element, depth) = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.02)
            if (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return nil }
            if isTextField(element) {
                if (attribute(element, kAXFocusedAttribute) as? Bool) == true { return element }
                if textReader(element).selection() != nil { candidates.append(element) }
                continue
            }
            guard depth < 4 else { continue }
            var values: CFArray?
            if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 16, &values) == .success,
               let children = values as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        if candidates.count == 1 { return candidates[0] }
        var ancestor = focus
        for _ in 0..<4 {
            guard ContinuousClock.now < deadline,
                  let parent = elementAttribute(ancestor, kAXParentAttribute) else { break }
            if (attribute(parent, kAXRoleAttribute) as? String) == kAXWindowRole { break }
            ancestor = parent
            if (attribute(parent, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return parent }
            if isTextField(parent) { return parent }
        }
        return nil
    }

    func submit(_ text: String, into snapshot: TextFieldSnapshot,
                canSubmit: () -> Bool = { true }) -> TextSubmission? {
        guard clipboardInsertion?.isActive != true, canSubmit(), !text.isEmpty,
              let current = captureText(), snapshot.matches(current) else {
            logger.notice("Paste cancelled: context validation failed")
            return nil
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let lease = ClipboardInsertion(pasteboard: .general) else {
            logger.notice("Paste cancelled: clipboard cannot be preserved")
            return nil
        }
        // Revalidate after materializing pasteboard providers, before any write.
        guard canSubmit(), let fresh = captureText(), snapshot.matches(fresh), lease.stage(text) else { return nil }
        guard canSubmit() else { lease.restore(); return nil }
        clipboardInsertion = lease
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: GlobalInputMonitor.syntheticMarker)
            event.postToPid(snapshot.pid)
        }
        logger.info("Native paste submitted")
        return TextSubmission { lease.finish(confirmed: $0) }
    }

    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite,
              dimensions.height.isFinite, dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func visibleBounds(_ element: AXUIElement) -> CGRect? {
        var result = frame(element)
        var ancestor = element
        for _ in 0..<8 {
            guard let parent = elementAttribute(ancestor, kAXParentAttribute) else { break }
            ancestor = parent
            if let role = attribute(parent, kAXRoleAttribute) as? String,
               [kAXScrollAreaRole, kAXWindowRole].contains(role), let bounds = frame(parent) {
                result = result.map { $0.intersection(bounds) } ?? bounds
            }
        }
        if let window = elementAttribute(element, kAXWindowAttribute), let bounds = frame(window) {
            result = result.map { $0.intersection(bounds) } ?? bounds
        }
        return result.flatMap { $0.isNull ? nil : $0 }
    }

    private func font(_ element: AXUIElement, at location: Int, caretHeight: CGFloat) -> NSFont {
        let range = CFRange(location: max(0, location - 1), length: location > 0 ? 1 : 0)
        if let attributed = textReader(element).attributedText(range), attributed.length > 0 {
            let attributes = attributed.attributes(at: 0, effectiveRange: nil)
            if let font = attributes[.font] as? NSFont { return font }
            if let info = attributes[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
               let size = info[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber, size.doubleValue > 0,
               let name = info[kAXFontNameKey.takeUnretainedValue() as String] as? String,
               let font = NSFont(name: name, size: CGFloat(size.doubleValue)) {
                return font
            }
        }
        return .systemFont(ofSize: min(72, max(8, caretHeight * 0.82)))
    }
}
