import Foundation

nonisolated struct CommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let timeout: Duration

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(15)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

nonisolated struct CommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

nonisolated enum CommandRunnerError: Error, Equatable, Sendable {
    case launchFailed(executable: String, description: String)
    case timedOut(executable: String)
    case unreadableOutput
}

nonisolated protocol ProcessRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

nonisolated struct LocalProcessRunner: ProcessRunning {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        let control = ProcessControl()

        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try control.execute(request)
                    }.value
                } onCancel: {
                    control.cancel()
                }
            }

            group.addTask {
                try await Task.sleep(for: request.timeout)
                throw CommandRunnerError.timedOut(executable: request.executableURL.path)
            }

            guard let firstResult = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return firstResult
        }
    }
}

private nonisolated final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func execute(_ request: CommandRequest) throws -> CommandResult {
        try Task.checkCancellation()

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        if let requestEnvironment = request.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(requestEnvironment) { _, requested in requested }
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        lock.withLock {
            self.process = process
        }

        do {
            try process.run()
        } catch {
            lock.withLock {
                self.process = nil
            }
            throw CommandRunnerError.launchFailed(
                executable: request.executableURL.path,
                description: error.localizedDescription
            )
        }

        let outputBox = LockedData()
        let errorBox = LockedData()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.value = standardOutput.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.value = standardError.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        process.waitUntilExit()
        readers.wait()

        lock.withLock {
            self.process = nil
        }

        guard let output = String(data: outputBox.value, encoding: .utf8),
              let error = String(data: errorBox.value, encoding: .utf8) else {
            throw CommandRunnerError.unreadableOutput
        }

        return CommandResult(
            standardOutput: output,
            standardError: error,
            exitCode: process.terminationStatus
        )
    }

    func cancel() {
        let activeProcess = lock.withLock { process }
        guard let activeProcess, activeProcess.isRunning else { return }
        activeProcess.terminate()
    }
}

private nonisolated final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
