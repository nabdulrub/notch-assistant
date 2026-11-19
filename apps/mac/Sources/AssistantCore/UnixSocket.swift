import Darwin
import Foundation

/// The local socket the app and the helper talk over. No network, no port: a
/// file under the user's own Application Support folder.
public enum UnixSocket {
    public static var standardPath: String {
        SettingsStore.standard.directory.appendingPathComponent("bridge.sock").path
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    private static func open() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    /// Binds and listens, replacing a socket file left behind by an earlier run.
    public static func listen(path: String) -> Int32? {
        guard var address = address(path), let descriptor = open() else { return nil }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        chmod(path, 0o600)
        return descriptor
    }

    public static func connect(path: String) -> Int32? {
        guard var address = address(path), let descriptor = open() else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    public static func accept(_ listener: Int32) -> Int32? {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }
}

/// One end of a newline-delimited connection.
public final class LineConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let writeLock = NSLock()
    private var closed = false
    private var pending = Data()

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    @discardableResult
    public func send(_ line: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        var payload = line
        payload.append(0x0A)
        return payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Blocks until one whole line has arrived. Nil when the other side has gone.
    /// Only one thread may read a connection.
    public func nextLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if line.isEmpty { continue }
                return line
            }
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { return nil }
            pending.append(chunk, count: count)
        }
    }

    /// Blocks, calling `handler` once per line, until the other side goes away.
    public func readLines(_ handler: (Data) -> Void) {
        while let line = nextLine() { handler(line) }
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }
}
