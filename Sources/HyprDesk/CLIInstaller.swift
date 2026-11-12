import AppKit

/// The menu's Install / Remove Command Line Tool: `hyprdesk` in /usr/local/bin, a link to
/// this copy of the app's binary (the app doubles as its command line). /usr/local/bin is on
/// every shell's PATH on macOS, but usually only an administrator can write there, so when
/// plain file calls aren't allowed it asks macOS for an administrator's password.
enum CLIInstaller {
    static let link = URL(fileURLWithPath: "/usr/local/bin/hyprdesk")

    enum State: Equatable {
        /// Links to a copy of HyprDesk that's there: this one or another (a build, an older
        /// install). Either works, since the command only talks to whichever HyprDesk is
        /// running.
        case installed(copy: URL)
        /// Links to a copy of HyprDesk that's gone (moved or deleted): the command is broken.
        case broken
        /// Something at that path that isn't ours.
        case foreign
        case missing
    }

    static var target: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    static var state: State {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return FileManager.default.fileExists(atPath: link.path) ? .foreign : .missing
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "hyprdesk", resolved.path.contains(".app/Contents/MacOS/") else { return .foreign }
        return FileManager.default.isExecutableFile(atPath: resolved.path) ? .installed(copy: resolved) : .broken
    }

    /// The installed command runs this copy of HyprDesk.
    static var isThisCopy: Bool {
        if case .installed(let copy) = state { copy.path == target?.path } else { false }
    }

    /// Links `hyprdesk` to this copy, replacing a broken link. Never replaces a file that isn't
    /// a HyprDesk link.
    static func install() -> Result<Void, Failure> {
        guard let target else { return .failure(.message("Couldn't find HyprDesk's own binary.")) }
        if state == .foreign { return .failure(.message("\(link.path) already exists and isn't HyprDesk's. Remove it first.")) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if state == .broken { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            return .success(())
        } catch {
            return asAdministrator("mkdir -p \(quoted(link.deletingLastPathComponent().path)) && ln -sfn \(quoted(target.path)) \(quoted(link.path))")
        }
    }

    /// Removes the link, only if it's a HyprDesk link.
    static func remove() -> Result<Void, Failure> {
        switch state {
        case .installed, .broken: break
        case .foreign, .missing: return .success(())
        }
        do {
            try FileManager.default.removeItem(at: link)
            return .success(())
        } catch {
            return asAdministrator("rm -f \(quoted(link.path))")
        }
    }

    enum Failure: Error {
        /// The password prompt was cancelled: nothing to tell.
        case cancelled
        case message(String)
    }

    /// Runs `command` through macOS's administrator password prompt.
    private static func asAdministrator(_ command: String) -> Result<Void, Failure> {
        let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .success(()) }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return .failure(.cancelled) }
        return .failure(.message(error[NSAppleScript.errorMessage] as? String ?? "macOS said no."))
    }

    /// For the shell: in single quotes, any single quote closed, escaped and reopened.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
