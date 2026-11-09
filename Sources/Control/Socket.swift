import Foundation

/// The private line between `hyprdesk <command>` and the running app: a Unix socket only this
/// user can open. One request per connection: `{"args": [...]}` and a newline in, one JSON
/// value back, then the app hangs up.
public enum ControlSocket {
    /// `~/Library/Application Support/HyprDesk/hyprdesk.sock` (`HYPRDESK_SOCKET` overrides it).
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["HYPRDESK_SOCKET"]
            ?? URL.applicationSupportDirectory.appending(path: "HyprDesk/hyprdesk.sock").path
    }

    struct Request: Codable { var args: [String] }

    public enum Failure: Error, CustomStringConvertible {
        case notRunning(String)
        case io(String)

        public var description: String {
            switch self {
            case .notRunning(let path): "HyprDesk isn't running (nothing listening at \(path))"
            case .io(let what): what
            }
        }
    }

    /// Sends `args` to the app at `path` and returns its answer.
    public static func send(_ args: [String], path: String = defaultPath) throws(Failure) -> JSON {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = address(path) else { throw .io("socket path too long: \(path)") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw .notRunning(path) }
        guard let request = try? JSONEncoder().encode(Request(args: args)), write(fd, request + Data("\n".utf8)) else {
            throw .io("couldn't send the command")
        }
        let answer = readAll(fd)
        guard let json = try? JSONDecoder().decode(JSON.self, from: answer) else { throw .io("no answer from HyprDesk") }
        return json
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Up to a newline (or the other end hanging up), at most `limit` bytes.
    static func readAll(_ fd: Int32, untilNewline: Bool = false, limit: Int = 4 << 20) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[..<n])
            if untilNewline, buffer[..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return data
    }
}

/// The app's end: answers each connection with `handler`'s JSON. Runs until `stop()`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) async -> JSON

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var fd: Int32 = -1

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws(ControlSocket.Failure) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)  // a previous run's, left by a crash
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io("socket: \(String(cString: strerror(errno)))") }
        guard var address = ControlSocket.address(path) else { close(fd); throw .io("socket path too long: \(path)") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw .io("couldn't listen at \(path): \(error)")
        }
        lock.withLock { self.fd = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "HyprDesk control"
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { self.fd = -1 }
            return self.fd
        }
        guard fd >= 0 else { return }
        close(fd)
        unlink(path)
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // closed by stop()
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let handler = handler
            Task.detached {
                defer { close(client) }
                let line = ControlSocket.readAll(client, untilNewline: true, limit: 1 << 20)
                let answer: JSON
                if let request = try? JSONDecoder().decode(ControlSocket.Request.self, from: line) {
                    answer = await handler(request.args)
                } else {
                    answer = .failure("couldn't read the request")
                }
                _ = ControlSocket.write(client, answer.encoded() + Data("\n".utf8))
            }
        }
    }
}
