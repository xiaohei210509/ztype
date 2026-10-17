struct AccessibleFocusResolver<Element> {
    struct Resolution {
        let focus: Element
        let editor: Element
    }

    let readFocus: () -> Element?
    let resolveEditor: (Element) -> Element?
    let enableEnhancedAccessibility: (Element) -> Bool

    func resolve() -> Resolution? {
        guard let focus = readFocus() else { return nil }
        if let editor = resolveEditor(focus) {
            return Resolution(focus: focus, editor: editor)
        }
        guard enableEnhancedAccessibility(focus),
              let refreshed = readFocus(),
              let editor = resolveEditor(refreshed) else { return nil }
        return Resolution(focus: refreshed, editor: editor)
    }

    static func requestEnhancement(
        current: () -> Bool?, isSettable: () -> Bool, enable: () -> Bool
    ) -> Bool {
        guard current() == false, isSettable() else { return false }
        return enable()
    }
}
