import Foundation

nonisolated enum StreamingProcessError: Error, Equatable, Sendable {
    case alreadyRunning
    case launchFailed(executable: String, description: String)
    case exited(code: Int32)
}

nonisolated protocol StreamingProcessLaunching: Sendable {
    func start(_ request: CommandRequest) throws -> AsyncThrowingStream<String, Error>
    func terminate()
}

nonisolated final class LocalStreamingProcess: StreamingProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    deinit {
        terminate()
    }

    func start(_ request: CommandRequest) throws -> AsyncThrowingStream<String, Error> {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        if let requestEnvironment = request.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(requestEnvironment) { _, requested in requested }
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var capturedContinuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error>(bufferingPolicy: .bufferingNewest(200)) {
            capturedContinuation = $0
        }
        guard let capturedContinuation else {
            throw StreamingProcessError.launchFailed(
                executable: request.executableURL.path,
                description: "Could not create the process output stream."
            )
        }

        let accepted = lock.withLock { () -> Bool in
            guard self.process == nil else { return false }
            self.process = process
            continuation = capturedContinuation
            return true
        }
        guard accepted else { throw StreamingProcessError.alreadyRunning }

        let yieldData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            capturedContinuation.yield(text)
        }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            yieldData(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            yieldData(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(process: process, exitCode: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            finish(
                process: process,
                error: StreamingProcessError.launchFailed(
                    executable: request.executableURL.path,
                    description: error.localizedDescription
                )
            )
            throw StreamingProcessError.launchFailed(
                executable: request.executableURL.path,
                description: error.localizedDescription
            )
        }
        return stream
    }

    func terminate() {
        let active = lock.withLock { () -> (Process?, AsyncThrowingStream<String, Error>.Continuation?) in
            let active = (process, continuation)
            process = nil
            continuation = nil
            return active
        }
        active.1?.finish(throwing: CancellationError())
        guard let activeProcess = active.0, activeProcess.isRunning else { return }
        activeProcess.terminate()
    }

    private func finish(process: Process, exitCode: Int32) {
        if exitCode == 0 {
            finish(process: process, error: nil)
        } else {
            finish(process: process, error: StreamingProcessError.exited(code: exitCode))
        }
    }

    private func finish(process finishedProcess: Process, error: Error?) {
        let activeContinuation = lock.withLock { () -> AsyncThrowingStream<String, Error>.Continuation? in
            guard process === finishedProcess else { return nil }
            let active = continuation
            continuation = nil
            process = nil
            return active
        }
        if let error {
            activeContinuation?.finish(throwing: error)
        } else {
            activeContinuation?.finish()
        }
    }
}
