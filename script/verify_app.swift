import AppKit
import Foundation
import CoreGraphics

enum VerificationFailure: Error {
    case failed(String)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationFailure.failed(message) }
}

do {
    let candidates = [
        "/Applications/ztype.app",
        NSHomeDirectory() + "/Applications/ztype.app",
        NSHomeDirectory() + "/Library/Caches/ztype/Application/ztype.app"
    ]
    let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ??
        ProcessInfo.processInfo.environment["ZTYPE_APP_PATH"] ??
        candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ??
        candidates.last!
    guard let bundle = Bundle(path: path) else {
        throw VerificationFailure.failed("Cannot load application bundle: \(path)")
    }
    for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
        try require(bundle.object(forInfoDictionaryKey: key) as? String == "ztype",
                    "\(key) must be lowercase ztype")
    }
    try require(bundle.bundleIdentifier == "app.ztype.mac", "Unexpected bundle identifier")
    try require(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
                "The application must be a menu-bar agent")
    try require(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon",
                "Missing application icon metadata")
    guard let iconURL = bundle.url(forResource: "AppIcon", withExtension: "icns"),
          let icon = NSImage(contentsOf: iconURL), icon.isValid else {
        throw VerificationFailure.failed("The packaged icon cannot be decoded")
    }
    let sizes = Set(icon.representations.map(\.pixelsWide))
    try require(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes),
                "Incomplete icon resolutions: \(sizes.sorted())")
    print("PASS: lowercase branding, independent bundle ID, agent metadata, icon resolutions")

    if CommandLine.arguments.contains("--project-entry") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let entry = root.appendingPathComponent("dist/ztype.app")
        try require(FileManager.default.fileExists(atPath: entry.path),
                    "The project application entry is missing or dangling")
        try require(entry.resolvingSymlinksInPath().standardizedFileURL.path ==
                    bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
                    "The project entry must point to the selected installed bundle")
        print("PASS: project entry resolves to the installed application")
    }

    if CommandLine.arguments.contains("--running") || CommandLine.arguments.contains("--keyboard-monitor") {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "app.ztype.mac")
            .filter { $0.bundleURL?.standardizedFileURL == bundle.bundleURL.standardizedFileURL }
        try require(applications.count == 1, "Expected exactly one running packaged application")
        try require(applications[0].activationPolicy == .accessory,
                    "Running application must not use regular Dock activation")
        print("PASS: one running ztype process with accessory activation policy")
        if CommandLine.arguments.contains("--keyboard-monitor") {
            var count: UInt32 = 0
            try require(CGGetEventTapList(0, nil, &count) == .success && count < 512,
                        "Cannot inspect actual event tap registrations")
            let capacity = count + 8
            var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
            try require(CGGetEventTapList(capacity, &taps, &count) == .success && count <= capacity,
                        "Cannot read actual event tap registrations")
            let owned = taps.prefix(Int(count)).filter {
                $0.tappingProcess == applications[0].processIdentifier &&
                $0.tapPoint == .cgSessionEventTap && $0.options == .defaultTap
            }
            let required = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel]
                .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            try require(owned.contains(where: { $0.enabled && $0.eventsOfInterest & required == required }),
                        "No complete keyboard event tap; actual masks: \(owned.map(\.eventsOfInterest))")
            print("PASS: actual enabled event tap includes keyDown, keyUp, modifiers and pointer invalidation")
        }
    }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
