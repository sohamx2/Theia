import Foundation

enum OllamaRuntimeError: LocalizedError {
    case executableNotFound
    case serverDidNotStart
    case commandFailed(String)
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Ollama is not installed. Install Ollama in /Applications so Theia can start it automatically."
        case .serverDidNotStart:
            return "Theia started Ollama, but its local server did not become available."
        case .commandFailed(let message):
            return "Ollama could not prepare the model. \(message)"
        case .invalidResponse:
            return "Ollama returned an invalid runtime response."
        case .http(let status, let message):
            return "Ollama returned HTTP \(status): \(message)"
        }
    }
}

protocol OllamaRuntimeManaging {
    func prepare(model: String) async throws
    func unload(model: String) async
}

extension OllamaRuntimeManaging {
    func unload(model: String) async {}
}

final class OllamaRuntimeManager: OllamaRuntimeManaging {
    static let shared = OllamaRuntimeManager(baseURL: LocalModelConfiguration.current.baseURL)

    private let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var ownedServerProcess: Process?
    private var activeCommandProcesses: [UUID: Process] = [:]
    private var preparedModels = Set<String>()
    private var cachedExecutableURL: URL?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func prepare(model: String) async throws {
        try Task.checkCancellation()
        try await ensureServerIsRunning()
        try Task.checkCancellation()

        if try await installedModelNames().contains(where: { modelNamesMatch($0, model) }) {
            rememberPreparedModel(model)
            return
        }

        if let executableURL = resolveExecutableURL() {
            _ = try await runCLI(
                executableURL: executableURL,
                arguments: ["pull", model]
            )
        } else {
            try await pullThroughAPI(model: model)
        }

        rememberPreparedModel(model)
    }

    func unload(model: String) async {
        guard await serverIsAvailable() else { return }
        let endpoint = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": "",
            "stream": false,
            "keep_alive": 0
        ])
        _ = try? await session.data(for: request)
        _ = lock.withLock {
            preparedModels.remove(model)
        }
    }

    /// Called synchronously from applicationWillTerminate. Models are unloaded,
    /// but their downloaded files remain on disk for the next Theia launch.
    func shutdown() {
        let snapshot: (models: [String], commands: [Process], server: Process?, executable: URL?) = lock.withLock {
            let snapshot = (
                models: Array(preparedModels),
                commands: Array(activeCommandProcesses.values),
                server: ownedServerProcess,
                executable: cachedExecutableURL ?? resolveExecutableURLUnlocked()
            )
            preparedModels.removeAll()
            activeCommandProcesses.removeAll()
            ownedServerProcess = nil
            return snapshot
        }

        for command in snapshot.commands where command.isRunning {
            command.terminate()
        }

        if let executableURL = snapshot.executable {
            for model in snapshot.models {
                runShutdownCommand(executableURL: executableURL, arguments: ["stop", model])
            }
        }

        // Do not terminate a pre-existing Ollama service because another app may
        // own it. Only terminate the server process launched by Theia itself.
        if let server = snapshot.server, server.isRunning {
            server.terminate()
        }
    }

    private func ensureServerIsRunning() async throws {
        if await serverIsAvailable() {
            return
        }

        let executableURL = try requireExecutableURL()
        let process: Process = try lock.withLock {
            if let existing = ownedServerProcess, existing.isRunning {
                return existing
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["serve"]
            process.environment = ollamaEnvironment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            ownedServerProcess = process
            return process
        }

        for _ in 0..<40 {
            try Task.checkCancellation()
            if await serverIsAvailable() {
                return
            }
            if !process.isRunning {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OllamaRuntimeError.serverDidNotStart
    }

    private func serverIsAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func installedModelNames() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaRuntimeError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw httpError(status: httpResponse.statusCode, data: data)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else {
            throw OllamaRuntimeError.invalidResponse
        }
        return models.compactMap { model in
            (model["name"] as? String) ?? (model["model"] as? String)
        }
    }

    private func pullThroughAPI(model: String) async throws {
        let endpoint = baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaRuntimeError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw httpError(status: httpResponse.statusCode, data: data)
        }
    }

    private func runCLI(
        executableURL: URL,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        let commandIdentifier = UUID()
        let output = Pipe()
        let buffer = CappedProcessOutput()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ollamaEnvironment()
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completedProcess in
                    _ = self.lock.withLock {
                        self.activeCommandProcesses.removeValue(forKey: commandIdentifier)
                    }
                    output.fileHandleForReading.readabilityHandler = nil
                    let remaining = output.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty { buffer.append(remaining) }
                    let text = buffer.text

                    if completedProcess.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        let detail = text.isEmpty
                            ? "`ollama \(arguments.joined(separator: " "))` exited with status \(completedProcess.terminationStatus)."
                            : text
                        continuation.resume(throwing: OllamaRuntimeError.commandFailed(detail))
                    }
                }

                do {
                    self.lock.withLock {
                        self.activeCommandProcesses[commandIdentifier] = process
                    }
                    try process.run()
                } catch {
                    _ = self.lock.withLock {
                        self.activeCommandProcesses.removeValue(forKey: commandIdentifier)
                    }
                    process.terminationHandler = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func runShutdownCommand(executableURL: URL, arguments: [String]) {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ollamaEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
            if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                process.terminate()
            }
        } catch {
            // The app is already terminating; cleanup is best-effort.
        }
    }

    private func requireExecutableURL() throws -> URL {
        guard let executableURL = resolveExecutableURL() else {
            throw OllamaRuntimeError.executableNotFound
        }
        return executableURL
    }

    private func resolveExecutableURL() -> URL? {
        lock.withLock {
            if let cachedExecutableURL { return cachedExecutableURL }
            let resolved = resolveExecutableURLUnlocked()
            cachedExecutableURL = resolved
            return resolved
        }
    }

    private func resolveExecutableURLUnlocked() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let configuredPath = environment["THEIA_OLLAMA_EXECUTABLE"]
            ?? UserDefaults.standard.string(forKey: "theia.ollamaExecutable")
        let pathCandidates = [configuredPath].compactMap { $0 } + [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "/Applications/Ollama.app/Contents/MacOS/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/usr/bin/ollama"
        ] + (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/ollama" }

        return pathCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private func ollamaEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let host = baseURL.host {
            let port = baseURL.port ?? 11434
            environment["OLLAMA_HOST"] = "\(host):\(port)"
        }
        return environment
    }

    private func rememberPreparedModel(_ model: String) {
        _ = lock.withLock { preparedModels.insert(model) }
    }

    private func modelNamesMatch(_ installed: String, _ requested: String) -> Bool {
        func canonical(_ value: String) -> String {
            value.lowercased().hasSuffix(":latest")
                ? String(value.lowercased().dropLast(7))
                : value.lowercased()
        }
        return canonical(installed) == canonical(requested)
    }

    private func httpError(status: Int, data: Data) -> OllamaRuntimeError {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = object?["error"] as? String
            ?? String(data: data, encoding: .utf8)
            ?? "Unknown Ollama runtime error"
        return .http(status, message)
    }
}

private final class CappedProcessOutput {
    private let lock = NSLock()
    private var data = Data()
    private let byteLimit = 64 * 1_024

    func append(_ newData: Data) {
        lock.withLock {
            data.append(newData)
            if data.count > byteLimit {
                data.removeFirst(data.count - byteLimit)
            }
        }
    }

    var text: String {
        lock.withLock {
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
