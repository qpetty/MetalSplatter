#if os(visionOS) || os(macOS) || os(iOS)

import Foundation
import os
import SplatIO

/// Format types for streaming data
enum StreamingFormatType: UInt32 {
    case spz = 0
    case ply = 1
}

/// Protocol for receiving streaming frame updates
protocol WebSocketStreamingClientDelegate: AnyObject {
    func streamingClient(_ client: WebSocketStreamingClient, didConnect serverInfo: WebSocketStreamingClient.ServerInfo)
    func streamingClient(_ client: WebSocketStreamingClient, didReceiveFrame frame: WebSocketStreamingClient.Frame)
    func streamingClient(_ client: WebSocketStreamingClient, didDisconnectWithError error: Error?)
    func streamingClient(_ client: WebSocketStreamingClient, didReceiveStatus status: WebSocketStreamingClient.ServerStatus)
}

/// WebSocket client for receiving SPZ/PLY Gaussian Splat data streams
class WebSocketStreamingClient: NSObject, ObservableObject {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WebSocketStreamingClient")
    
    /// Server welcome info
    struct ServerInfo {
        let protocolVersion: Int
        let format: String
        let formatType: StreamingFormatType
        let headerSize: Int
        let serverTime: TimeInterval
    }
    
    /// A single frame of Gaussian splat data
    struct Frame {
        let sequenceId: UInt32
        let formatType: StreamingFormatType
        let data: Data
    }
    
    /// Server status response
    struct ServerStatus {
        let totalFramesBroadcast: Int
        let totalBytesBroadcast: Int
        let totalMBBroadcast: Double
        let currentClients: Int
        let peakClients: Int
        let uptimeSeconds: Double
        let clientFramesReceived: Int
        let clientBytesReceived: Int
        let lastSeqId: Int
        let isPaused: Bool
        let connectionDuration: Double
    }
    
    // MARK: - Published Properties
    
    @MainActor @Published var isConnected = false
    @MainActor @Published var isPaused = false
    @MainActor @Published var lastSequenceId: UInt32 = 0
    @MainActor @Published var framesReceived: Int = 0
    @MainActor @Published var bytesReceived: Int = 0
    @MainActor @Published var serverInfo: ServerInfo?
    @MainActor @Published var connectionError: String?
    
    // MARK: - Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    weak var delegate: WebSocketStreamingClientDelegate?
    
    private static let headerSize = 12 // 4 bytes seq_id + 4 bytes format_type + 4 bytes data_length
    
    // Callback for frame data - alternative to delegate pattern
    var onFrameReceived: ((Frame) -> Void)?
    
    // MARK: - Connection
    
    /// Connect to WebSocket server
    /// - Parameters:
    ///   - host: Server hostname or IP address
    ///   - port: Server port (default: 8765)
    func connect(host: String, port: Int = 8765) {
        guard let url = URL(string: "ws://\(host):\(port)") else {
            Self.log.error("Invalid WebSocket URL: ws://\(host):\(port)")
            Task { @MainActor in
                self.connectionError = "Invalid URL"
            }
            return
        }
        
        Self.log.info("Connecting to WebSocket: \(url.absoluteString)")
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: url)
        
        // Set maximum message size to 50MB to handle large SPZ/PLY frames
        webSocketTask?.maximumMessageSize = 50 * 1024 * 1024
        
        webSocketTask?.resume()
        
        Task { @MainActor in
            self.connectionError = nil
        }
        
        receiveMessage()
    }
    
    /// Disconnect from WebSocket server
    func disconnect() {
        Self.log.info("Disconnecting from WebSocket")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        
        Task { @MainActor in
            self.isConnected = false
            self.isPaused = false
        }
    }
    
    // MARK: - Control Messages
    
    /// Send ping to check connection
    func sendPing() {
        sendJSON(["type": "ping"])
    }
    
    /// Request server status
    func requestStatus() {
        sendJSON(["type": "status"])
    }
    
    /// Pause streaming
    func pause() {
        sendJSON(["type": "pause"])
    }
    
    /// Resume streaming
    func resume() {
        sendJSON(["type": "resume"])
    }
    
    /// Send client info (optional, for debugging)
    func sendClientInfo(device: String, appVersion: String) {
        sendJSON([
            "type": "client_info",
            "info": [
                "device": device,
                "app_version": appVersion
            ]
        ])
    }
    
    // MARK: - Private Methods
    
    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else {
            Self.log.error("Failed to serialize JSON message")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(string)
        webSocketTask?.send(message) { error in
            if let error = error {
                Self.log.error("Failed to send message: \(error.localizedDescription)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleBinaryFrame(data)
                case .string(let text):
                    self.handleTextMessage(text)
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()
                
            case .failure(let error):
                Self.log.error("WebSocket receive error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.isConnected = false
                    self.connectionError = error.localizedDescription
                }
                self.delegate?.streamingClient(self, didDisconnectWithError: error)
            }
        }
    }
    
    private func handleBinaryFrame(_ data: Data) {
        guard data.count >= Self.headerSize else {
            Self.log.warning("Received binary frame too small: \(data.count) bytes")
            return
        }
        
        // Parse header (big-endian)
        let seqId = data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let formatTypeRaw = data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let dataLength = data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard data.count >= Self.headerSize + Int(dataLength) else {
            Self.log.warning("Incomplete frame: expected \(Self.headerSize + Int(dataLength)) bytes, got \(data.count)")
            return
        }
        
        let formatType = StreamingFormatType(rawValue: formatTypeRaw) ?? .spz
        let gaussianData = Data(data[12..<(12 + Int(dataLength))])
        
        let frame = Frame(sequenceId: seqId, formatType: formatType, data: gaussianData)
        
        Self.log.debug("Received frame \(seqId): \(dataLength) bytes (\(formatType == .spz ? "SPZ" : "PLY"))")
        
        Task { @MainActor in
            self.lastSequenceId = seqId
            self.framesReceived += 1
            self.bytesReceived += Int(dataLength)
        }
        
        // Notify delegate or callback
        delegate?.streamingClient(self, didReceiveFrame: frame)
        onFrameReceived?(frame)
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            Self.log.warning("Received invalid JSON message")
            return
        }
        
        switch type {
        case "welcome":
            handleWelcome(json)
        case "pong":
            Self.log.debug("Pong received")
        case "status":
            handleStatus(json)
        case "paused":
            Task { @MainActor in
                self.isPaused = true
            }
            Self.log.info("Streaming paused")
        case "resumed":
            Task { @MainActor in
                self.isPaused = false
            }
            Self.log.info("Streaming resumed")
        default:
            Self.log.debug("Received message type: \(type)")
        }
    }
    
    private func handleWelcome(_ json: [String: Any]) {
        let protocolVersion = json["protocol_version"] as? Int ?? 1
        let format = json["format"] as? String ?? "unknown"
        let formatTypeRaw = json["format_type"] as? Int ?? 0
        let headerSize = json["header_size"] as? Int ?? 12
        let serverTime = json["server_time"] as? Double ?? 0
        
        let formatType = StreamingFormatType(rawValue: UInt32(formatTypeRaw)) ?? .spz
        
        let info = ServerInfo(
            protocolVersion: protocolVersion,
            format: format,
            formatType: formatType,
            headerSize: headerSize,
            serverTime: serverTime
        )
        
        Self.log.info("Connected to server - Protocol: \(protocolVersion), Format: \(format)")
        
        Task { @MainActor in
            self.isConnected = true
            self.serverInfo = info
        }
        
        delegate?.streamingClient(self, didConnect: info)
    }
    
    private func handleStatus(_ json: [String: Any]) {
        let clientInfo = json["client"] as? [String: Any] ?? [:]
        
        let status = ServerStatus(
            totalFramesBroadcast: json["total_frames_broadcast"] as? Int ?? 0,
            totalBytesBroadcast: json["total_bytes_broadcast"] as? Int ?? 0,
            totalMBBroadcast: json["total_mb_broadcast"] as? Double ?? 0,
            currentClients: json["current_clients"] as? Int ?? 0,
            peakClients: json["peak_clients"] as? Int ?? 0,
            uptimeSeconds: json["uptime_seconds"] as? Double ?? 0,
            clientFramesReceived: clientInfo["frames_received"] as? Int ?? 0,
            clientBytesReceived: clientInfo["bytes_received"] as? Int ?? 0,
            lastSeqId: clientInfo["last_seq_id"] as? Int ?? 0,
            isPaused: clientInfo["paused"] as? Bool ?? false,
            connectionDuration: clientInfo["connection_duration"] as? Double ?? 0
        )
        
        delegate?.streamingClient(self, didReceiveStatus: status)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketStreamingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Self.log.info("WebSocket connection opened")
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Self.log.info("WebSocket connection closed with code: \(closeCode.rawValue)")
        Task { @MainActor in
            self.isConnected = false
        }
        delegate?.streamingClient(self, didDisconnectWithError: nil)
    }
}

// MARK: - Frame Processing Helper

extension WebSocketStreamingClient {
    /// Process a frame and return SplatScenePoints
    /// - Parameter frame: The received frame
    /// - Returns: Array of SplatScenePoints, or nil if processing failed
    static func processFrame(_ frame: Frame) async throws -> [SplatScenePoint] {
        switch frame.formatType {
        case .spz:
            return try SPZLoader.loadPoints(from: frame.data)
        case .ply:
            return try await loadPLYFromData(frame.data)
        }
    }
    
    /// Load PLY data from memory
    private static func loadPLYFromData(_ data: Data) async throws -> [SplatScenePoint] {
        let inputStream = InputStream(data: data)
        let reader = SplatPLYSceneReader(inputStream)
        
        var buffer = SplatMemoryBuffer()
        try await buffer.read(from: reader)
        return buffer.points
    }
}

#endif // os(visionOS) || os(macOS) || os(iOS)

