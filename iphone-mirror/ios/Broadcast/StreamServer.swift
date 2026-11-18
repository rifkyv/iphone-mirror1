import Darwin
import Foundation

/// TCP server bound to 127.0.0.1 that the PC reaches through usbmuxd (the USB cable).
/// One client at a time. A new client replaces the old one.
final class StreamServer {
    private let port: UInt16
    private let stateLock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var pendingBytes = 0
    private let sendQueue = DispatchQueue(label: "mirror.send")

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onCommand: (([String: Any]) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - lifecycle

    func start() {
        stateLock.lock()
        running = true
        stateLock.unlock()
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "mirror.accept"
        thread.start()
    }

    func stop() {
        stateLock.lock()
        running = false
        let lfd = listenFD
        let cfd = clientFD
        listenFD = -1
        stateLock.unlock()
        if lfd >= 0 {
            Darwin.shutdown(lfd, SHUT_RDWR)
            Darwin.close(lfd)
        }
        if cfd >= 0 {
            // The reader thread notices and closes the socket.
            Darwin.shutdown(cfd, SHUT_RDWR)
        }
    }

    var hasClient: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clientFD >= 0
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    // MARK: - sending

    /// Queue `data` for the current client. Returns false when there is no client, or when
    /// `droppable` is true and more than `maxQueued` bytes are already waiting.
    @discardableResult
    func send(_ data: Data, droppable: Bool, maxQueued: Int) -> Bool {
        stateLock.lock()
        let fd = clientFD
        if fd < 0 || (droppable && pendingBytes > maxQueued) {
            stateLock.unlock()
            return false
        }
        pendingBytes += data.count
        stateLock.unlock()

        sendQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillCurrent = (self.clientFD == fd)
            self.stateLock.unlock()
            if stillCurrent {
                self.writeAll(fd, data)
            }
            self.stateLock.lock()
            self.pendingBytes = max(0, self.pendingBytes - data.count)
            self.stateLock.unlock()
        }
        return true
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.send(fd, pointer, remaining, 0)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    // Send timeout or broken connection: drop this client.
                    Darwin.shutdown(fd, SHUT_RDWR)
                    return
                }
            }
        }
    }

    // MARK: - accepting

    private func makeListener() -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || Darwin.listen(fd, 4) != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private func acceptLoop() {
        while isRunning {
            stateLock.lock()
            var fd = listenFD
            stateLock.unlock()
            if fd < 0 {
                fd = makeListener()
                if fd < 0 {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                stateLock.lock()
                if running {
                    listenFD = fd
                    stateLock.unlock()
                } else {
                    stateLock.unlock()
                    Darwin.close(fd)
                    return
                }
            }

            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if !isRunning { return }
                if errno == EINTR { continue }
                stateLock.lock()
                if listenFD == fd { listenFD = -1 }
                stateLock.unlock()
                Darwin.close(fd)
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            configure(client)
            attach(client)
        }
    }

    private func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var sendBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func attach(_ fd: Int32) {
        stateLock.lock()
        let previous = clientFD
        clientFD = fd
        pendingBytes = 0
        stateLock.unlock()
        if previous >= 0 {
            Darwin.shutdown(previous, SHUT_RDWR)
        }
        onConnect?()
        let reader = Thread { [weak self] in
            self?.readLoop(fd)
        }
        reader.name = "mirror.read"
        reader.start()
    }

    // MARK: - reading commands (JSON lines)

    private func readLoop(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line),
                   let command = object as? [String: Any] {
                    onCommand?(command)
                }
            }
            if buffer.count > 65536 {
                buffer.removeAll()
            }
        }

        stateLock.lock()
        let wasCurrent = (clientFD == fd)
        if wasCurrent { clientFD = -1 }
        stateLock.unlock()
        // Close on the send queue so no queued write can hit a reused descriptor number.
        sendQueue.async {
            Darwin.close(fd)
        }
        if wasCurrent {
            onDisconnect?()
        }
    }
}
