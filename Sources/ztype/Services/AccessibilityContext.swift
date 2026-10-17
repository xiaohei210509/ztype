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

enum ContextCaptureFailure: Equatable {
    case noPermission, secureInput, composition, noApplication, ownApplication, excluded
    case noField, unsupportedField, secureField, disabledField, noSelection, selectedText
    case noText, noCharacterCount, noCaret, noVisibleBounds, offscreen

    var mayBeLayoutDelay: Bool {
        switch self {
        case .noField, .unsupportedField, .noSelection, .noText, .noCharacterCount, .noCaret, .noVisibleBounds: return true
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
    private let isCompositionInputSource: @MainActor () -> Bool
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private var clipboardInsertion: ClipboardInsertion?
    var hasActiveInsertion: Bool { clipboardInsertion?.isActive == true }

    func finishShutdown() { clipboardInsertion?.restore() }
    private let logger = Logger(subsystem: "app.ztype.mac", category: "Acceptance")
    private let captureLogger = Logger(subsystem: "app.ztype.mac", category: "Compatibility")
    private(set) var failure: ContextCaptureFailure?
    private(set) var diagnostics: CompatibilityDiagnostics?
    private(set) var applicationName = ""
    private var applicationIdentifier = ""
    private var diagnosticFocus: AXUIElement?
    private var diagnosticEditor: AXUIElement?
    private var enhancedApplication: NSRunningApplication?
    var excluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.agilebits.onepassword7", "com.1password.1password",
        "com.apple.keychainaccess"
    ]

    init(isCompositionInputSource: @escaping @MainActor () -> Bool = { AccessibilityContext.compositionInputSource },
         frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.isCompositionInputSource = isCompositionInputSource
        self.frontmostApplication = frontmostApplication
    }

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
        applicationIdentifier = ""
        diagnosticFocus = nil
        diagnosticEditor = nil
        guard Self.trusted else { return fail(.noPermission) }
        guard !IsSecureEventInputEnabled() else { return fail(.secureInput) }
        guard !isCompositionInputSource() else { return fail(.composition) }
        guard let app = frontmostApplication() else { return fail(.noApplication) }
        applicationName = app.localizedName ?? app.bundleIdentifier ?? ""
        applicationIdentifier = app.bundleIdentifier ?? ""
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return fail(.ownApplication) }
        guard !excluded.contains(app.bundleIdentifier ?? "") else { return fail(.excluded) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.06)
        let resolved = focusedField(in: application)
        guard let focus = diagnosticFocus else { return fail(.noField) }
        guard let element = resolved?.editor else { return fail(.unsupportedField) }
        diagnosticEditor = element
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
        if !applicationIdentifier.isEmpty,
           [.unsupportedField, .noSelection, .noText, .noCharacterCount, .noCaret, .noVisibleBounds, .offscreen].contains(reason) {
            let focus = diagnosticFocus.map(elementDiagnostics)
            let report = CompatibilityDiagnostics(
                application: applicationIdentifier, reason: reason.message,
                focus: focus,
                editor: diagnosticEditor.flatMap { editor in
                    if let element = diagnosticFocus, CFEqual(editor, element) { return focus }
                    return elementDiagnostics(editor)
                }
            )
            if diagnostics != report {
                captureLogger.notice("Capture failed: \(String(describing: reason), privacy: .public), role: \(report.focus?.role ?? "", privacy: .public)")
            }
            diagnostics = report
        }
        return nil
    }

    private func elementDiagnostics(_ element: AXUIElement) -> CompatibilityDiagnostics.Element {
        AXUIElementSetMessagingTimeout(element, 0.01)
        let deadline = ContinuousClock.now + .milliseconds(25)
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return CompatibilityDiagnostics.Element(
            attribute: { ContinuousClock.now < deadline ? self.attribute(element, $0) : nil },
            parameters: (names as? [String]) ?? [], valueSettable: settable.boolValue
        )
    }

    private func parameter(_ element: AXUIElement, _ key: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, key as CFString, parameter, &value
        ) == .success else { return nil }
        return value
    }

    func textReader(_ element: AXUIElement, includeChildBounds: Bool = true) -> AccessibleTextReader {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        let supported = Set((names as? [String]) ?? [])
        return AccessibleTextReader(attribute: { self.attribute(element, $0) }, parameter: { key, value in
            guard supported.isEmpty || supported.contains(key) else { return nil }
            return self.parameter(element, key, value)
        }, boundsFallback: includeChildBounds ? { self.focusedChildBounds(element, range: $0) } : nil)
    }

    private func focusedChildBounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        let reader = textReader(element, includeChildBounds: false)
        guard let selection = reader.selection(), selection.range.length == 0 else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 65, &values) == .success,
              let children = values as? [AXUIElement], children.count <= 64 else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(25)
        var found: CGRect?
        for child in children {
            guard ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, 0.015)
            guard attribute(child, kAXRoleAttribute) as? String == kAXStaticTextRole,
                  attribute(child, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { continue }
            let childReader = textReader(child, includeChildBounds: false)
            guard let childSelection = childReader.selection(), childSelection.range.length == 0,
                  let local = AccessibleTextReader.relativeRange(
                    range, cursor: selection.range.location, childCursor: childSelection.range.location
                  ) else { continue }
            let length = min(1600, childSelection.range.location)
            // Child indices are local, not document offsets. Validate the actual text,
            // rather than interpreting AXIndexForChildUIElement as a character index.
            guard let childText = childReader.text(CFRange(
                location: childSelection.range.location - length, length: length
            )), let parentText = reader.text(CFRange(
                location: selection.range.location - length, length: length
            )), childText == parentText, let rect = childReader.bounds(local),
                  let fresh = childReader.selection(),
                  fresh.range.location == childSelection.range.location, fresh.range.length == 0 else { continue }
            guard found == nil else { return nil }
            found = rect
        }
        guard let fresh = reader.selection(), fresh.range.location == selection.range.location,
              fresh.range.length == 0 else { return nil }
        return found
    }

    private func isTextField(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let editable = attribute(element, "AXEditable") as? Bool
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
            return editable != false
        }
        guard editable == true || ["AXLayoutArea", "AXLayoutItem", kAXGroupRole].contains(role) else { return false }
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        let supported = Set((names as? [String]) ?? [])
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let line = attribute(element, kAXInsertionPointLineNumberAttribute) as? NSNumber
        return AccessibleFieldCapabilities(
            role: role, editable: editable, valueSettable: settable.boolValue,
            hasSelection: textReader(element).selection() != nil,
            hasTextRanges: !supported.isDisjoint(with: [kAXStringForRangeParameterizedAttribute,
                kAXAttributedStringForRangeParameterizedAttribute, "AXStringForTextMarkerRange"]),
            hasInsertionLine: line.map { $0.intValue >= 0 && $0.intValue < Int.max } ?? false
        ).isEditor
    }

    func focusedField(in application: AXUIElement) -> AccessibleFocusResolver<AXUIElement>.Resolution? {
        AccessibleFocusResolver(
            readFocus: {
                self.diagnosticFocus = self.elementAttribute(application, kAXFocusedUIElementAttribute)
                return self.diagnosticFocus
            },
            resolveEditor: { self.resolveField($0) },
            enableEnhancedAccessibility: { self.enableEnhancedAccessibility(application, focus: $0) }
        ).resolve()
    }

    private func enableEnhancedAccessibility(_ application: AXUIElement, focus: AXUIElement) -> Bool {
        let role = attribute(focus, kAXRoleAttribute) as? String ?? ""
        guard [kAXScrollAreaRole, kAXGroupRole, "AXLayoutArea", "AXLayoutItem", "AXPage", "AXWebArea"].contains(role)
        else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              !excluded.contains(app.bundleIdentifier ?? "") else { return false }
        if let previous = enhancedApplication, !previous.isTerminated, previous.processIdentifier == pid {
            return false
        }
        // One request per active application, never one per keystroke.
        enhancedApplication = app
        let key = "AXEnhancedUserInterface"
        let enabled = AccessibleFocusResolver<AXUIElement>.requestEnhancement(
            current: { self.attribute(application, key) as? Bool },
            isSettable: {
                var settable: DarwinBoolean = false
                return AXUIElementIsAttributeSettable(application, key as CFString, &settable) == .success &&
                    settable.boolValue
            },
            enable: {
                AXUIElementSetAttributeValue(application, key as CFString, kCFBooleanTrue) == .success
            }
        )
        if enabled {
            captureLogger.notice("Requested enhanced text accessibility for a focused container")
        }
        return enabled
    }

    func resolveField(_ focus: AXUIElement) -> AXUIElement? {
        let deadline = ContinuousClock.now + .milliseconds(50)
        var classification: [AXUIElement: AccessibleFieldResolver<AXUIElement>.Kind] = [:]
        let resolver = AccessibleFieldResolver<AXUIElement>(
            equal: { CFEqual($0, $1) },
            kind: { element in
                if let cached = classification[element] { return cached }
                AXUIElementSetMessagingTimeout(element, 0.02)
                let kind: AccessibleFieldResolver<AXUIElement>.Kind
                let role = self.attribute(element, kAXRoleAttribute) as? String ?? ""
                if self.attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                    kind = .secure
                } else if [kAXWindowRole, kAXApplicationRole, kAXToolbarRole, kAXMenuBarRole].contains(role) {
                    kind = .boundary
                } else if role == "AXWebArea", !self.isTextField(element) {
                    kind = .boundary
                } else if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXLayoutArea", "AXLayoutItem"].contains(role),
                          self.attribute(element, "AXEditable") as? Bool == false {
                    kind = .blocked
                } else { kind = self.isTextField(element) ? .editor : .container }
                classification[element] = kind
                return kind
            },
            focused: { self.attribute($0, kAXFocusedAttribute) as? Bool == true },
            hasSelection: { self.textReader($0).selection() != nil },
            parent: { self.elementAttribute($0, kAXParentAttribute) },
            children: { element in
                var values: CFArray?
                // Do not silently truncate the children and then claim a unique editor.
                guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 65, &values) == .success
                else { return [] }
                return (values as? [AXUIElement]) ?? []
            },
            withinBudget: { ContinuousClock.now < deadline }
        )
        return resolver.resolve(focus)
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
