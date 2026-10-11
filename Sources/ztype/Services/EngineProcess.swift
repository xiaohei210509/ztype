import Foundation
import ztypeCore
import Darwin

@MainActor
final class EngineProcess {
    private var process: Process?
    private var client: InferenceClient?
    private var idleTask: Task<Void, Never>?
    private var startup: Task<InferenceClient, Error>?
    var onState: ((String) -> Void)?
    private(set) var pid: Int32?

    func ready() async throws -> InferenceClient {
        idleTask?.cancel()
        if let client, process?.isRunning == true { return client }
        if let startup { return try await startup.value }
        let task = Task<InferenceClient, Error> { @MainActor in
            let resources = Bundle.main.resourceURL!
            let executable = resources.appendingPathComponent("engine/llama-server")
            let model = resources.appendingPathComponent("Qwen3-1.7B-Q8_0.gguf")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  FileManager.default.fileExists(atPath: model.path) else {
                throw EngineFailure.missingRuntime
            }
            let port = try Self.freePort()
            let key = UUID().uuidString + UUID().uuidString
            let candidate = InferenceClient(port: port, key: key)
            let child = Process()
            child.executableURL = executable
            child.currentDirectoryURL = resources.appendingPathComponent("engine")
            child.arguments = [
                "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                "--api-key", key, "-c", "2048", "-ngl", "99",
                "-t", "3", "-tb", "3", "--parallel", "1",
                "--poll", "0", "--poll-batch", "0", "--prio", "-1",
                "-b", "256", "-ub", "128", "--no-webui", "--log-disable",
                "--sleep-idle-seconds", "90"
            ]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            onState?("正在加载本地模型")
            try child.run()
            process = child
            pid = child.processIdentifier
            for _ in 0..<300 {
                try Task.checkCancellation()
                guard child.isRunning else {
                    onState?("本地模型启动失败")
                    throw EngineFailure.exited(child.terminationStatus)
                }
                if await candidate.healthy() {
                    client = candidate
                    onState?("本地模型就绪")
                    return candidate
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            stop()
            throw EngineFailure.launchFailed
        }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    func rest(after seconds: Double = 90) {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.stop()
            self?.onState?("空闲休眠 · 模型已卸载")
        }
    }

    func stop() {
        idleTask?.cancel()
        startup?.cancel()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        client = nil
        pid = nil
    }

    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw EngineFailure.launchFailed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw EngineFailure.launchFailed }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard named == 0 else { throw EngineFailure.launchFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

enum EngineFailure: LocalizedError {
    case missingRuntime, launchFailed, exited(Int32)
    var errorDescription: String? {
        switch self {
        case .missingRuntime: return "本地模型未安装，请运行项目的 setup_engine.py。"
        case .launchFailed: return "本地推理进程未能启动。"
        case .exited(let code): return "本地推理进程退出（\(code)）。"
        }
    }
}
