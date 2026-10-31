import Foundation

struct Proposal: Equatable {
    var branch: String?
    var message: String

    static func validateMessage(_ message: String) throws {
        guard isSingleLine(message), message.utf8.count <= 500,
              message.range(of: "^[a-z][a-z0-9-]*(\\([^()\\r\\n]+\\))?!?: \\S.*$", options: .regularExpression) != nil else {
            throw ShipError.message("Use a single-line conventional message, for example fix: reject empty login credentials (maximum 500 bytes; no controls).")
        }
    }

    static func decode(_ data: Data, needsBranch: Bool) throws -> Proposal {
        guard data.count <= 16384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["branch", "message"], let message = object["message"] as? String else {
            throw ShipError.message("cmd returned invalid JSON. Raw output was withheld.")
        }
        let branch: String?
        if needsBranch {
            guard let value = object["branch"] as? String, isSingleLine(value) else {
                throw ShipError.message("cmd did not propose a valid new branch.")
            }
            branch = value
        } else {
            guard object["branch"] is NSNull else { throw ShipError.message("cmd must return branch: null on a work branch.") }
            branch = nil
        }
        try validateMessage(message)
        return Proposal(branch: branch, message: message)
    }
}

protocol Generating {
    func generate(_ payload: Data, needsBranch: Bool) throws -> Proposal
}

/// A temporary Command Code mod calls its documented, context-free model.complete API.
/// The print-mode query is static: the scanned payload is read only by the bridge,
/// never by the ordinary agent or its context/skill discovery.
final class CommandCode: Generating {
    private let runner: ProcessRunner
    init(runner: ProcessRunner) { self.runner = runner }

    func generate(_ payload: Data, needsBranch: Bool) throws -> Proposal {
        guard let executable = runner.executable("cmd") else { throw ShipError.message("cmd is missing from PATH.") }
        let isolated = try TemporaryDirectory()
        var environment = runner.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["COMMANDCODE_SKIP_UPDATES"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        let result = try runner.run(executable, ["--help"], cwd: isolated.url, environment: environment, timeout: 10)
        let help = String(decoding: result.stdout, as: UTF8.self)
        let required = ["--mod", "--no-skills", "--no-session", "--max-turns", "--permission-mode", "--no-auto-update", "--skip-onboarding"]
        guard result.status == 0, required.allSatisfy(help.contains) else {
            throw ShipError.message("This cmd installation lacks the generation bridge controls. Use manual entry or update cmd.")
        }
        let bridge = isolated.url.appendingPathComponent("ship-generation.mjs")
        try Data(Self.bridgeSource.utf8).write(to: bridge)
        environment["COMMANDCODE_MODS_HOT_RELOAD"] = "0"
        let response = try runner.run(executable, [
            "-p", "ship generation bridge; do not perform any task",
            "--max-turns", "1", "--no-session",
            "--no-skills", "--skip-onboarding", "--no-auto-update",
            "--permission-mode", "dont-ask", "--mod", bridge.path
        ], cwd: isolated.url, input: payload, environment: environment, timeout: 90)
        guard response.status == 0,
              let object = try? JSONSerialization.jsonObject(with: response.stdout) as? [String: Any],
              object["shipBridge"] as? Int == 1,
              let answer = object["text"] as? String else {
            throw ShipError.message("cmd generation failed or its tool-free bridge was unavailable. Check cmd login/model access; raw output was withheld.")
        }
        return try Proposal.decode(Data(answer.utf8), needsBranch: needsBranch)
    }

    // Only static adapter code is written to disk. Repository bytes stay in stdin.
    // transformContext runs before the ordinary agent's model request. Exiting here
    // prevents that request altogether, including when model.complete is unavailable.
    static let bridgeSource = #"""
    import { writeSync } from 'node:fs';
    export default function shipGeneration(cmd) {
      cmd.setActiveTools([]);
      cmd.hooks({
        beforeToolCall() { return { block: true, terminate: true }; },
        async transformContext() {
          try {
            // cmd has already initialized Node's stdin stream, which may make
            // fd 0 nonblocking. A synchronous read can throw EAGAIN between
            // chunks of a large diff. Read the stream through EOF instead.
            const chunks = [];
            for await (const chunk of process.stdin) {
              chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
            }
            const prompt = Buffer.concat(chunks).toString('utf8');
            if (!prompt || typeof cmd.model?.complete !== 'function') process.exit(1);
            const result = await cmd.model.complete({ prompt, maxOutputTokens: 1024 });
            if (!result.isAnswered || typeof result.text !== 'string') process.exit(1);
            const output = Buffer.from(JSON.stringify({ shipBridge: 1, text: result.text }));
            let offset = 0;
            while (offset < output.length) offset += writeSync(1, output, offset);
            process.exit(0);
          } catch {
            process.exit(1);
          }
        }
      });
    }
    """#
}
