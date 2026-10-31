import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private final class Capture: @unchecked Sendable {
    var data = Data()
    var overflow = false
    var failed = false
    func drain(_ handle: FileHandle, limit: Int) {
        defer { try? handle.close() }
        do {
            while let block = try handle.read(upToCount: 65536), !block.isEmpty {
                if data.count + block.count <= limit { data.append(block) }
                else { overflow = true }
            }
        } catch { failed = true }
    }
    func deliver(_ input: Data, to handle: FileHandle) {
        defer { try? handle.close() }
        do { try handle.write(contentsOf: input) }
        catch { failed = true }
    }
}

final class ProcessRunner {
    let environment: [String: String]
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        signal(SIGPIPE, SIG_IGN)
    }

    func executable(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        // Never discover executables in the repository through a relative PATH component.
        for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func run(_ executable: String, _ args: [String], cwd: URL, input: Data = Data(),
             environment: [String: String]? = nil, timeout: TimeInterval = 120,
             interactive: Bool = false) throws -> CommandResult {
        if Interrupt.requested { throw ShipError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = environment ?? self.environment
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        let output = Capture(), error = Capture(), delivery = Capture()
        let group = DispatchGroup()
        if interactive {
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
        }
        do { try process.run() }
        catch { throw ShipError.message("Could not start \(URL(fileURLWithPath: executable).lastPathComponent).") }
        if !interactive {
            // All three pipes run concurrently: neither large stdin nor stderr can deadlock stdout.
            group.enter()
            DispatchQueue.global().async {
                output.drain(outputPipe.fileHandleForReading, limit: 64 * 1024 * 1024)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                error.drain(errorPipe.fileHandleForReading, limit: 4 * 1024 * 1024)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                delivery.deliver(input, to: inputPipe.fileHandleForWriting)
                group.leave()
            }
        }
        let started = Date()
        var interruptedAt: Date?
        var timedOut = false
        while process.isRunning {
            if Interrupt.requested || (timeout > 0 && Date().timeIntervalSince(started) > timeout) {
                timedOut = !Interrupt.requested
                if interruptedAt == nil { process.interrupt(); interruptedAt = Date() }
                else if Date().timeIntervalSince(interruptedAt!) > 1 { kill(process.processIdentifier, SIGKILL) }
            }
            // Foundation delivers Process termination through the calling run loop on macOS.
            // Sleeping here can leave isRunning stale after a fast child has already exited.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        process.waitUntilExit()
        // A hook might leave descendants holding pipes open. Do not wait forever.
        guard group.wait(timeout: .now() + 5) == .success else {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            throw ShipError.message("Subprocess left open streams; stopped without continuing.")
        }
        if Interrupt.requested { throw ShipError.cancelled }
        if timedOut { throw ShipError.message("Subprocess timed out.") }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if delivery.failed { throw ShipError.message("\(name) closed its input before receiving all the data (exit \(process.terminationStatus)).") }
        if output.failed || error.failed { throw ShipError.message("Couldn't finish reading \(name)'s response (exit \(process.terminationStatus)).") }
        if output.overflow || error.overflow { throw ShipError.message("Subprocess output exceeded the safe size limit.") }
        return CommandResult(status: process.terminationStatus, stdout: output.data, stderr: error.data)
    }
}
