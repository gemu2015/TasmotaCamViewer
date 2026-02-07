import Foundation
import Network

/// Low-level UDP client for the Tasmota I2S bridge audio protocol.
///
/// Uses POSIX UDP sockets for the audio data path (reliable, no NWListener issues)
/// and an NWConnection for control commands.
///
/// - Audio socket: bound to local port 6970, sends to and receives from ESP32:6970.
/// - Control connection: NWConnection to ESP32:6971 for text commands.
final class UDPAudioClient: @unchecked Sendable {

    // MARK: - Types

    enum Event: Sendable {
        case audioData(Data)
        case connected
        case error(AudioBridgeError)
        case completed
    }

    // MARK: - Properties

    private var audioSocketFD: Int32 = -1
    private var controlConnection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?
    private var isActive = false
    private var receiveThread: Thread?
    private var espAddress: sockaddr_in?
    private let queue = DispatchQueue(label: "UDPAudioClient.queue", qos: .userInteractive)

    // MARK: - Public

    /// Connect to the ESP32 host. Returns an AsyncStream of events.
    func connect(to host: String) -> AsyncStream<Event> {
        cancel()

        return AsyncStream { continuation in
            self.continuation = continuation
            self.isActive = true

            // 1. Create POSIX UDP socket for audio data on port 6970
            self.setupAudioSocket(host: host)

            // 2. Create NWConnection for control commands → ESP32:6971
            let nwHost = NWEndpoint.Host(host)
            let ctrlPort = NWEndpoint.Port(rawValue: Constants.audioBridgeControlPort)!
            let ctrlParams = NWParameters.udp
            self.controlConnection = NWConnection(host: nwHost, port: ctrlPort, using: ctrlParams)

            self.controlConnection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[UDPAudioClient] Control connection ready (→ \(host):\(Constants.audioBridgeControlPort))")
                    self?.continuation?.yield(.connected)
                case .failed(let error):
                    print("[UDPAudioClient] Control connection failed: \(error)")
                    self?.continuation?.yield(.error(.udpConnectionFailed(underlying: error)))
                default:
                    break
                }
            }
            self.controlConnection?.start(queue: self.queue)

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// Send a control command (e.g., "cmd:1") to ESP32 port 6971.
    func sendControl(_ command: String) {
        guard let controlConnection, isActive else {
            print("[UDPAudioClient] Cannot send control: not connected")
            return
        }

        let data = Data(command.utf8)
        controlConnection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[UDPAudioClient] Control send error: \(error)")
            } else {
                print("[UDPAudioClient] Sent control: '\(command)'")
            }
        })
    }

    /// Send raw PCM audio data to ESP32 port 6970.
    func sendAudio(_ data: Data) {
        guard audioSocketFD >= 0, isActive, var addr = espAddress else { return }

        data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(audioSocketFD, base, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Cancel all connections.
    func cancel() {
        isActive = false

        // Close the POSIX socket — this unblocks the recvfrom() in the receive thread
        if audioSocketFD >= 0 {
            close(audioSocketFD)
            audioSocketFD = -1
        }

        receiveThread?.cancel()
        receiveThread = nil

        controlConnection?.cancel()
        controlConnection = nil

        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    /// Set up a POSIX UDP socket bound to local port 6970 and start a receive thread.
    private func setupAudioSocket(host: String) {
        // Create UDP socket
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            print("[UDPAudioClient] Failed to create socket: \(String(cString: strerror(errno)))")
            continuation?.yield(.error(.udpConnectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))))
            return
        }

        // Allow address reuse
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to local port 6970
        var localAddr = sockaddr_in()
        localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = Constants.audioBridgeDataPort.bigEndian
        localAddr.sin_addr.s_addr = INADDR_ANY  // already 0, no byte swap needed

        let bindResult = withUnsafePointer(to: &localAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult < 0 {
            print("[UDPAudioClient] Failed to bind to port \(Constants.audioBridgeDataPort): \(String(cString: strerror(errno)))")
            close(fd)
            continuation?.yield(.error(.udpConnectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))))
            return
        }

        // Store the ESP32 destination address for sendto()
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = Constants.audioBridgeDataPort.bigEndian
        host.withCString { cstr in
            inet_pton(AF_INET, cstr, &destAddr.sin_addr)
        }
        self.espAddress = destAddr

        // Set receive timeout so the thread can check isActive periodically
        var tv = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        self.audioSocketFD = fd
        print("[UDPAudioClient] Audio socket bound to port \(Constants.audioBridgeDataPort), sending to \(host):\(Constants.audioBridgeDataPort)")

        // Start background receive thread
        let thread = Thread { [weak self] in
            self?.receiveLoop()
        }
        thread.name = "UDPAudioClient.receive"
        thread.qualityOfService = .userInteractive
        self.receiveThread = thread
        thread.start()
    }

    /// Background loop: block on recvfrom() and yield audio data events.
    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var packetCount: UInt64 = 0

        print("[UDPAudioClient] Receive loop started")

        while isActive && audioSocketFD >= 0 {
            let n = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(audioSocketFD, &buffer, buffer.count, 0, sa, &senderLen)
                }
            }

            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                packetCount += 1
                if packetCount == 1 {
                    let ip = String(cString: inet_ntoa(senderAddr.sin_addr))
                    let port = UInt16(bigEndian: senderAddr.sin_port)
                    print("[UDPAudioClient] First packet received: \(n) bytes from \(ip):\(port)")
                } else if packetCount % 500 == 0 {
                    print("[UDPAudioClient] Received \(packetCount) packets")
                }
                continuation?.yield(.audioData(data))
            } else if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Timeout — just loop and check isActive
                    continue
                }
                if err == EBADF || !isActive {
                    // Socket closed — exit
                    break
                }
                print("[UDPAudioClient] recvfrom error: \(String(cString: strerror(err)))")
            }
        }

        print("[UDPAudioClient] Receive loop ended")
    }
}
