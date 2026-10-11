import CoreGraphics
import Foundation

enum KeyboardMonitoringStatus: Equatable {
    case inactive, ready, incomplete, unavailable

    static let events: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel
    ]
    static let requiredMask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

    var title: String {
        switch self {
        case .inactive: return "未启动"
        case .ready: return "可用"
        case .incomplete: return "键盘事件被系统拒绝"
        case .unavailable: return "监听检查失败"
        }
    }

    static func evaluate(_ taps: [CGEventTapInformation], pid: pid_t) -> Self {
        let owned = taps.filter {
            $0.tappingProcess == pid && $0.tapPoint == .cgSessionEventTap && $0.options == .defaultTap
        }
        guard !owned.isEmpty else { return .inactive }
        if owned.contains(where: { $0.enabled && $0.eventsOfInterest & requiredMask == requiredMask }) {
            return .ready
        }
        return owned.contains(where: { $0.eventsOfInterest & requiredMask != requiredMask }) ?
            .incomplete : .unavailable
    }

    static func current(pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> Self {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return .unavailable }
        guard count > 0 else { return .inactive }
        guard count < 512 else { return .unavailable }
        let capacity = count + 8
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        guard CGGetEventTapList(capacity, &taps, &count) == .success,
              count <= capacity else { return .unavailable }
        return evaluate(Array(taps.prefix(Int(count))), pid: pid)
    }
}
