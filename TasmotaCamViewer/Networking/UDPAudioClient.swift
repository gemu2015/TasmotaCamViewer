import Foundation
import Network

/// Low-level UDP client for the Tasmota I2S bridge audio protocol.
///
/// Manages three network objects:
/// - `sendConnection`: NWConnection to ESP32 port 6970 for sending audio data
/// - `controlConnection`: NWConnection to ESP32 port 6971 for sending control commands
/// - `listener`: NWListener on local port 6970 for receiving audio data from ESP32
final class UDPAudioClient: @unchecked Sendable {

    // MARK: - Types

    enum Event: Sendable {
        case audioData(Data)
        case connected
        case error(AudioBridgeError)
        case completed
    }

    // MARK: - Properties

    private var sendConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var listener: NWListener?
    private var incomingConnection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?
    private var isActive = false
    private let queue = DispatchQueue(label: "UDPAudioClient.queue", qos: .userInteractive)

    // MARK: - Public

    /// Connect to the ESP32 host. Returns an AsyncStream of events.
    /// Sending a control command to port 6971 registers the iOS device's IP with the ESP32.
    func connect(to host: String) -> AsyncStream<Event> {
        cancel()

        return AsyncStream { continuation in
            self.continuation = continuation
            self.isActive = true

            let nwHost = NWEndpoint.Host(host)

            // 1. Create send connection for audio data → ESP32:6970
            let sendPort = NWEndpoint.Port(rawValue: Constants.audioBridgeDataPort)!
            let udpParams = NWParameters.udp
            self.sendConnection = NWConnection(host: nwHost, port: sendPort, using: udpParams)

            self.sendConnection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[UDPAudioClient] Send connection ready (→ \(host):\(Constants.audioBridgeDataPort))")
                case .failed(let error):
                    print("[UDPAudioClient] Send connection failed: \(error)")
                    self?.continuation?.yield(.error(.udpConnectionFailed(underlying: error)))
                default:
                    break
                }
            }
            self.sendConnection?.start(queue: self.queue)

            // 2. Create control connection → ESP32:6971
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

            // 3. Create listener on local port 6970 to receive audio from ESP32
            self.startListener()

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// Send a control command (e.g., "cmd:1") to ESP32 port 6971.
    /// This also registers the iOS device's IP as the audio destination on the ESP32.
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
        guard let sendConnection, isActive else { return }

        sendConnection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[UDPAudioClient] Audio send error: \(error)")
            }
        })
    }

    /// Cancel all connections and the listener.
    func cancel() {
        isActive = false

        sendConnection?.cancel()
        sendConnection = nil

        controlConnection?.cancel()
        controlConnection = nil

        incomingConnection?.cancel()
        incomingConnection = nil

        listener?.cancel()
        listener = nil

        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    /// Start an NWListener on local port 6970 to receive incoming audio from the ESP32.
    private func startListener() {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.any),
            port: NWEndpoint.Port(rawValue: Constants.audioBridgeDataPort)!
        )

        do {
            let newListener = try NWListener(using: params)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[UDPAudioClient] Listener ready on port \(Constants.audioBridgeDataPort)")
                case .failed(let error):
                    print("[UDPAudioClient] Listener failed: \(error)")
                    self?.continuation?.yield(.error(.udpConnectionFailed(underlying: error)))
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] newConnection in
                guard let self, self.isActive else {
                    newConnection.cancel()
                    return
                }
                // Replace previous incoming connection
                self.incomingConnection?.cancel()
                self.incomingConnection = newConnection
                newConnection.start(queue: self.queue)
                self.receiveFromConnection(newConnection)
            }

            newListener.start(queue: queue)
        } catch {
            print("[UDPAudioClient] Failed to create listener: \(error)")
            continuation?.yield(.error(.udpConnectionFailed(underlying: error)))
        }
    }

    /// Continuously receive data from an incoming UDP connection.
    private func receiveFromConnection(_ connection: NWConnection) {
        guard isActive else { return }

        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.isActive else { return }

            if let data, !data.isEmpty {
                self.continuation?.yield(.audioData(data))
            }

            if let error {
                print("[UDPAudioClient] Receive error: \(error)")
                // Don't treat individual receive errors as fatal — keep listening
            }

            // Continue receiving
            self.receiveFromConnection(connection)
        }
    }
}
