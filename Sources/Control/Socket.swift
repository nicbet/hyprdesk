import Foundation

/// The private line between `hyprdesk <command>` and the running app: a Unix socket only this
/// user can open. One request per connection: `{"args": [...]}` and a newline in, one JSON
/// value back, then the app hangs up. Except `subscribe`: the connection stays open and the app
/// writes one JSON value per line, the answer then every event, until either end hangs up.
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
        let fd = try connected(args, path: path)
        defer { close(fd) }
        let answer = readAll(fd)
        guard let json = try? JSONDecoder().decode(JSON.self, from: answer) else { throw .io("no answer from HyprDesk") }
        return json
    }

    /// Sends `args` (a `subscribe`) and hands every line the app writes to `line`, the answer
    /// first, until the app hangs up or `line` returns false.
    public static func stream(_ args: [String], path: String = defaultPath, line: (Data) -> Bool) throws(Failure) {
        let fd = try connected(args, path: path)
        defer { close(fd) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            pending.append(contentsOf: buffer[..<n])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let text = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                if !text.isEmpty, !line(Data(text)) { return }
            }
        }
    }

    /// A connection to the app with `args` sent.
    private static func connected(_ args: [String], path: String) throws(Failure) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = address(path) else { close(fd); throw .io("socket path too long: \(path)") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); throw .notRunning(path) }
        guard let request = try? JSONEncoder().encode(Request(args: args)), write(fd, request + Data("\n".utf8)) else {
            close(fd)
            throw .io("couldn't send the command")
        }
        return fd
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

/// The app's end: answers each connection with `handler`'s JSON, and keeps `subscribe`
/// connections for `broadcast`. Runs until `stop()`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) async -> JSON

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var fd: Int32 = -1
    /// Open `subscribe` connections and the events each asked for. Under `lock`.
    private var subscribers: [(fd: Int32, filter: [String])] = []
    /// Writes to subscribers happen here, in order, off the caller's thread.
    private let writes = DispatchQueue(label: "HyprDesk control events")

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
        writes.sync {
            let open = lock.withLock { () -> [Int32] in
                defer { subscribers = [] }
                return subscribers.map(\.fd)
            }
            for fd in open { close(fd) }
        }
    }

    /// Writes `events`, one line each, to every subscriber that asked for them. A subscriber
    /// that has gone, or stops reading for a couple of seconds, is dropped.
    public func broadcast(_ events: [JSON]) {
        guard !events.isEmpty, lock.withLock({ !subscribers.isEmpty }) else { return }
        let lines = events.map { ($0, $0.encoded() + Data("\n".utf8)) }
        writes.async { [self] in
            for subscriber in lock.withLock({ subscribers }) {
                let data = lines.filter { EventState.matches($0.0, filter: subscriber.filter) }.reduce(Data()) { $0 + $1.1 }
                guard !data.isEmpty, !ControlSocket.write(subscriber.fd, data) else { continue }
                lock.withLock { subscribers.removeAll { $0.fd == subscriber.fd } }
                close(subscriber.fd)
            }
        }
    }

    public var subscriberCount: Int { lock.withLock { subscribers.count } }

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
            Task.detached { [weak self] in
                let line = ControlSocket.readAll(client, untilNewline: true, limit: 1 << 20)
                let answer: JSON
                var filter: [String]?
                if let request = try? JSONDecoder().decode(ControlSocket.Request.self, from: line) {
                    if case .subscribe(let events)? = try? Command.parse(request.args) { filter = events }
                    answer = await handler(request.args)
                } else {
                    answer = .failure("couldn't read the request")
                }
                guard let self, let filter, answer["ok"] == true else {
                    _ = ControlSocket.write(client, answer.encoded() + Data("\n".utf8))
                    close(client)
                    return
                }
                // The answer goes out on the events queue, so no event can overtake it.
                self.writes.async {
                    guard ControlSocket.write(client, answer.encoded() + Data("\n".utf8)) else { close(client); return }
                    // A subscriber that stops reading is dropped rather than holding up the rest.
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    self.lock.withLock { self.subscribers.append((client, filter)) }
                }
            }
        }
    }
}
