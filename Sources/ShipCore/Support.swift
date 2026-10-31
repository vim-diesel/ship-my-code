import Foundation
import Darwin

enum ShipError: Error, CustomStringConvertible {
    case message(String)
    case cancelled
    case notRepository
    var description: String {
        switch self {
        case .message(let message): return message
        case .cancelled: return "Cancelled."
        case .notRepository: return "This folder isn't a Git repository yet."
        }
    }
}

/// Escape terminal controls, including bidi controls, without hiding diff lines.
func display(_ text: String, multiline: Bool = false) -> String {
    text.unicodeScalars.map { c in
        if multiline && (c == "\n" || c == "\t") { return String(c) }
        if CharacterSet.controlCharacters.contains(c) || CharacterSet.newlines.contains(c)
            || c.properties.generalCategory == .format {
            return String(format: "\\u{%04X}", c.value)
        }
        return String(c)
    }.joined()
}

func isSingleLine(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && $0.properties.generalCategory != .format
        }
}

func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func utf8(_ data: Data) throws -> String {
    guard let value = String(data: data, encoding: .utf8) else {
        throw ShipError.message("Git returned non-UTF-8 paths or text; handle this selection manually.")
    }
    return value
}

extension String {
    var removingFinalNewline: String { hasSuffix("\n") ? String(dropLast()) : self }
}

final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ship-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

protocol Console: AnyObject {
    var interactive: Bool { get }
    func write(_ text: String)
    func read(_ prompt: String) throws -> String
}

public final class TerminalConsole: Console {
    public init() {}
    var interactive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }
    func write(_ text: String) { print(text) }
    func read(_ prompt: String) throws -> String {
        print(prompt, terminator: " ")
        fflush(stdout)
        var bytes = Data()
        while true {
            if Interrupt.requested { throw ShipError.cancelled }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno != EINTR { throw ShipError.cancelled }
            if ready <= 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { throw ShipError.cancelled }
            if count < 0 {
                if errno == EINTR { continue }
                throw ShipError.cancelled
            }
            if byte == 10 { return try utf8(bytes) }
            bytes.append(byte)
            if bytes.count > 8192 { throw ShipError.message("Input is too long.") }
        }
    }
}

public enum Interrupt {
    // Only the signal handler writes; normal execution observes this atomic-sized flag.
    static var requested = false
    public static func install() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT) { _ in Interrupt.requested = true }
        signal(SIGTERM) { _ in Interrupt.requested = true }
    }
}

struct Options {
    var staged = false
    var remote = "origin"
    var help = false
    var pullRequest = false
    var merge = false
    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--staged": staged = true
            case "--pr": pullRequest = true
            case "--merge": merge = true
            case "--help", "-h": help = true
            case "--remote":
                i += 1
                guard i < args.count, isSingleLine(args[i]), !args[i].hasPrefix("-") else {
                    throw ShipError.message("--remote needs a remote name.")
                }
                remote = args[i]
            default: throw ShipError.message("Unknown argument. Use ship --help for available commands.")
            }
            i += 1
        }
        if (pullRequest || merge) && staged { throw ShipError.message("--pr and --merge work on your branch's commits. Use ship --staged first to commit selected changes.") }
    }
    static let usage = """
    Usage: ship [--staged | --pr | --merge] [--remote NAME] [--help]

    Get a commit suggestion, review your changes, then approve the commit and push.

    ship                 Include all changes across the project, except ignored files.
    ship --staged        Include only changes already selected with git add.
    ship --remote NAME   Use another Git connection instead of origin.
    ship --pr            Generate and review a PR into a branch you select.
    ship --merge         Create/reuse a PR, squash merge, and clean up the work branch.
    ship --help          Show this help.

    New projects: set up Git, choose a GitHub repo name and private/public visibility.
    On main: choose a direct commit or a suggested new branch. Work branches keep their name.
    PR/merge targets list main first. Uncommitted changes must be shipped first or cancelled.

    Uses your cmd login and selected model, with local gitleaks checks first.
    Enter at the approval prompt cancels. Selected changes remain staged.
    """
}
