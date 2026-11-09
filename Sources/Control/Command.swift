import Foundation

/// A workspace as named on the command line: its number (as on ✦ 1–9), its name, or one of the
/// two special places.
public enum WorkspaceRef: Equatable, Sendable {
    /// 1-based, as shown in the sidebar.
    case number(Int)
    case name(String)
    case everywhere
    case scratchpad

    public init(_ text: String) {
        switch text.lowercased() {
        case "everywhere", "every", "all": self = .everywhere
        case "scratchpad", "scratch": self = .scratchpad
        default: self = Int(text).map(WorkspaceRef.number) ?? .name(text)
        }
    }

    /// Its position among workspaces called `names` (0-based): the number, else the name (exact,
    /// ignoring case), else the one name it begins. nil for the special places or no match.
    public func index(in names: [String]) -> Int? {
        switch self {
        case .number(let n): return names.indices.contains(n - 1) ? n - 1 : nil
        case .name(let name):
            if let exact = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
            let starts = names.indices.filter { names[$0].lowercased().hasPrefix(name.lowercased()) }
            return starts.count == 1 ? starts[0] : nil
        case .everywhere, .scratchpad: return nil
        }
    }
}

public enum ScratchpadAction: String, Equatable, Sendable {
    case toggle, show, hide
}

/// What `hyprdesk <command>` and `hyprdesk://<command>` can ask the running app.
public enum Command: Equatable, Sendable {
    case list
    case current
    case switchTo(WorkspaceRef)
    case previous
    /// `window` nil: the focused window. `follow`: switch along to the workspace it went to.
    case move(to: WorkspaceRef, window: UInt32?, follow: Bool)
    case focus(window: UInt32)
    case scratchpad(ScratchpadAction)
    case find(query: String?)
    case create(name: String)
    case rename(WorkspaceRef, to: String)
    case help

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// From the words after `hyprdesk`.
    public static func parse(_ args: [String]) throws(ParseError) -> Command {
        var words: [String] = []
        var window: UInt32?
        var stay = false
        var rest = args[...]
        while let word = rest.popFirst() {
            switch word {
            case "--window", "-w":
                guard let value = rest.popFirst(), let id = UInt32(value) else { throw ParseError("--window needs a window ID (see `hyprdesk list`)") }
                window = id
            case "--stay": stay = true
            case "--help", "-h": return .help
            default: words.append(word)
            }
        }
        guard let name = words.first else { return .help }
        let operands = Array(words.dropFirst())
        /// The operands as one name: workspace names may have spaces.
        func one(_ what: String) throws(ParseError) -> String {
            guard !operands.isEmpty else { throw ParseError("usage: hyprdesk \(name) <\(what)>") }
            return operands.joined(separator: " ")
        }
        switch name.lowercased() {
        case "list", "ls": return .list
        case "current", "status": return .current
        case "switch", "go": return .switchTo(WorkspaceRef(try one("workspace")))
        case "previous", "back": return .previous
        case "move":
            let target = WorkspaceRef(try one("workspace"))
            if case .everywhere = target {} else if case .scratchpad = target {} else {
                return .move(to: target, window: window, follow: window == nil && !stay)
            }
            return .move(to: target, window: window, follow: false)
        case "focus":
            guard let id = window ?? operands.first.flatMap(UInt32.init) else { throw ParseError("usage: hyprdesk focus <window-id>") }
            return .focus(window: id)
        case "scratchpad", "scratch":
            guard operands.count <= 1 else { throw ParseError("usage: hyprdesk scratchpad [toggle|show|hide]") }
            guard let action = ScratchpadAction(rawValue: operands.first?.lowercased() ?? "toggle") else {
                throw ParseError("usage: hyprdesk scratchpad [toggle|show|hide]")
            }
            return .scratchpad(action)
        case "find", "search": return .find(query: operands.isEmpty ? nil : operands.joined(separator: " "))
        case "create", "new":
            guard !operands.isEmpty else { throw ParseError("usage: hyprdesk create <name>") }
            return .create(name: operands.joined(separator: " "))
        case "rename":
            guard operands.count >= 2 else { throw ParseError("usage: hyprdesk rename <workspace> <new name>") }
            return .rename(WorkspaceRef(operands[0]), to: operands.dropFirst().joined(separator: " "))
        case "help": return .help
        default: throw ParseError("unknown command “\(name)”; run `hyprdesk help`")
        }
    }

    /// From a `hyprdesk://` link: the host is the command, path parts its words, and `?window=`
    /// and `?stay` its options. `hyprdesk://switch/2`, `hyprdesk://move/Work?window=1234`,
    /// `hyprdesk://find?q=slack`.
    public static func parse(url: URL) throws(ParseError) -> Command {
        guard url.scheme?.lowercased() == "hyprdesk", let host = url.host(), !host.isEmpty else {
            throw ParseError("not a hyprdesk:// link")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var args = [host] + url.pathComponents.filter { $0 != "/" }
        if let query = items.first(where: { $0.name == "q" })?.value { args.append(query) }
        if let window = items.first(where: { $0.name == "window" })?.value { args += ["--window", window] }
        if items.contains(where: { $0.name == "stay" }) { args.append("--stay") }
        return try parse(args)
    }

    /// Whether `word` starts a command (so the binary acts as the command line, not the app).
    public static func isCommand(_ word: String) -> Bool {
        ["list", "ls", "current", "status", "switch", "go", "previous", "back", "move", "focus", "scratchpad", "scratch",
         "find", "search", "create", "new", "rename", "help", "--help", "-h"].contains(word.lowercased())
    }

    public static let usage = """
    hyprdesk — control HyprDesk from the command line. Every command prints JSON.

      hyprdesk list                         workspaces and their windows (IDs, apps, titles)
      hyprdesk current                      the workspace on screen and the focused window
      hyprdesk switch <workspace>           switch to it
      hyprdesk previous                     back to the previous workspace
      hyprdesk move <workspace>             move the focused window there and follow it
               [--window <id>] [--stay]     another window (no following), or don't follow
      hyprdesk focus <window-id>            focus a window, switching to its workspace
      hyprdesk scratchpad [toggle|show|hide]
      hyprdesk find [text]                  open the window search (✦ Space)
      hyprdesk create <name>                a new workspace, at the end
      hyprdesk rename <workspace> <name>

    <workspace> is a number (1 = first in the sidebar), a name (or the start of one),
    `everywhere` (shown in every workspace) or `scratchpad`.

    The same as links: hyprdesk://switch/2, hyprdesk://move/Work?window=1234,
    hyprdesk://scratchpad/toggle, hyprdesk://find?q=slack
    """
}
