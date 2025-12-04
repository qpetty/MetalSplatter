#if os(visionOS)

import Foundation
import Network
import os

// Note: SPZ C function bindings are defined in SPZConverter.swift

class PLYStreamingServer: NSObject, ObservableObject, NetServiceDelegate {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "PLYStreamingServer")
    
    @MainActor @Published var isRunning = false
    @MainActor @Published var localIPAddress: String = "Not available"
    @MainActor @Published var lastReceivedFileURL: URL?
    @MainActor @Published var lastCaptureID: String?
    @MainActor @Published var localNetworkPermissionDenied: Bool = false
    @MainActor @Published var lastRequestParameters: [String: String] = [:]
    
    private var listener: NWListener?
    private var bonjourService: NetService?
    private var browser: NWBrowser?
    private let port: UInt16 = 8080
    private let serviceType = "_plystream._tcp"
    private let serviceDomain = "local."
    private let serviceName = "MetalSplatter PLY Stream"
    private let documentsDirectory: URL
    private let currentPLYFileName = "current_stream.ply"
    
    var onFileReceived: ((URL, String?) -> Void)?
    
    override init() {
        // Get app's documents directory
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        super.init()
        
        // Create a subdirectory for received PLY files
        let plyDirectory = documentsDirectory.appendingPathComponent("ReceivedPLYFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: plyDirectory, withIntermediateDirectories: true)
    }
    
    var currentPLYFileURL: URL {
        documentsDirectory
            .appendingPathComponent("ReceivedPLYFiles", isDirectory: true)
            .appendingPathComponent(currentPLYFileName)
    }
    
    @MainActor
    func start() {
        guard !isRunning else { return }
        
        // Start browser first to trigger permission prompt
        startBrowser()
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            
            // Enable TCP Keepalive to maintain long connections
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 10 // Send keepalive after 10 seconds of idle
                tcpOptions.keepaliveInterval = 5 // Retrospect every 5 seconds
                tcpOptions.keepaliveCount = 5 // Fail after 5 missed keepalives
            }
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.updateLocalIPAddress()
                        self?.startBonjourService()
                        Self.log.info("Server started on port \(self?.port ?? 0)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.stopBonjourService()
                        self?.stopBrowser()
                        Self.log.error("Server failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isRunning = false
                        self?.stopBonjourService()
                        self?.stopBrowser()
                        Self.log.info("Server stopped")
                    default:
                        break
                    }
                }
            }
            
            listener?.start(queue: DispatchQueue.global(qos: .userInitiated))
        } catch {
            Self.log.error("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func stop() {
        stopBonjourService()
        stopBrowser()
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    @MainActor
    private func startBonjourService() {
        // Stop any existing service first
        stopBonjourService()
        
        // Create and publish Bonjour service to trigger local network permission
        // Note: Bonjour may fail if permission is denied, but the server can still accept direct connections
        let service = NetService(domain: serviceDomain, type: serviceType, name: serviceName, port: Int32(port))
        service.delegate = self
        service.publish(options: [])
        bonjourService = service
        
        Self.log.info("Attempting to publish Bonjour service: \(self.serviceName).\(self.serviceType)\(self.serviceDomain)")
    }
    
    @MainActor
    private func stopBonjourService() {
        bonjourService?.stop()
        bonjourService?.delegate = nil
        bonjourService = nil
    }
    
    @MainActor
    private func startBrowser() {
        // Start NWBrowser to trigger local network permission prompt
        // This is often more reliable than just publishing a service
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)
        browser = NWBrowser(for: descriptor, using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    Self.log.info("Browser ready - local network permission granted")
                    self?.localNetworkPermissionDenied = false
                case .failed(let error):
                    Self.log.warning("Browser failed: \(error.localizedDescription)")
                    // Don't set permission denied here - browser failure doesn't mean permission denied
                case .cancelled:
                    Self.log.info("Browser cancelled")
                default:
                    break
                }
            }
        }
        
        browser?.browseResultsChangedHandler = { results, changes in
            // Just having the browser active helps trigger permission
            // We don't need to do anything with the results
        }
        
        browser?.start(queue: DispatchQueue.global(qos: .userInitiated))
        Self.log.info("Started NWBrowser to trigger local network permission")
    }
    
    @MainActor
    private func stopBrowser() {
        browser?.cancel()
        browser = nil
    }
    
    nonisolated private func updateLocalIPAddress() {
        var address = "Not available"
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            Task { @MainActor in
                self.localIPAddress = address
            }
            return
        }
        
        defer { freeifaddrs(ifaddr) }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                
                // Prefer en0 (WiFi) or en1 (Ethernet), skip loopback
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                               socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname,
                               socklen_t(hostname.count),
                               nil,
                               socklen_t(0),
                               NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break // Found IPv4 address
                }
            }
        }
        
        Task { @MainActor in
            self.localIPAddress = address != "Not available" ? "\(address):\(port)" : address
        }
    }
    
    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        
        // Use a class to hold state for this connection
        class ConnectionState {
            var receivedData = Data()
            var contentLength: Int?
            var boundary: String?
            var isHeaderComplete = false
            var requestPath: String?
            var lastLoggedSize = 0
            var keepAlive = false
            var idleTimer: DispatchSourceTimer?
            
            func reset() {
                receivedData = Data()
                contentLength = nil
                boundary = nil
                isHeaderComplete = false
                requestPath = nil
                lastLoggedSize = 0
                keepAlive = false
            }
        }
        
        let state = ConnectionState()
        let idleTimeout: TimeInterval = 30.0 // 30 seconds idle timeout
        
        // Setup idle timeout timer
        func setupIdleTimer() {
            state.idleTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + idleTimeout)
            timer.setEventHandler {
                Self.log.info("Connection idle timeout, closing")
                connection.cancel()
            }
            timer.resume()
            state.idleTimer = timer
        }
        
        func cancelIdleTimer() {
            state.idleTimer?.cancel()
            state.idleTimer = nil
        }
        
        func receiveNext() {
            // Reset idle timer on each receive
            if state.keepAlive {
                setupIdleTimer()
            }
            // Increased maximumLength to 1MB for better throughput on large files
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
                if let error = error {
                    Self.log.error("Connection error: \(error.localizedDescription)")
                    self?.sendErrorResponse(connection, statusCode: 500, message: "Internal Server Error", keepAlive: false) { _ in }
                    return
                }
                
                if let data = data, !data.isEmpty {
                    if !state.isHeaderComplete {
                        state.receivedData.append(data)
                        
                        // Look for end of headers (CRLF CRLF)
                        if let headerEndRange = state.receivedData.range(of: "\r\n\r\n".data(using: .utf8)!) {
                            let headerData = state.receivedData.subdata(in: 0..<headerEndRange.lowerBound)
                            let bodyStart = headerEndRange.upperBound
                            
                            // Parse headers
                            if let headers = String(data: headerData, encoding: .utf8) {
                                Self.log.info("Received headers: \(headers)")
                                state.requestPath = self?.parseRequestPath(from: headers)
                                state.contentLength = self?.parseContentLength(from: headers)
                                state.boundary = self?.parseBoundary(from: headers)
                                state.keepAlive = self?.parseKeepAlive(from: headers) ?? false
                                Self.log.info("Request: \(state.requestPath ?? "nil"), Content-Length: \(state.contentLength ?? -1), Keep-Alive: \(state.keepAlive)")
                                
                                // Reserve capacity if we know the content length to avoid reallocations
                                if let len = state.contentLength {
                                    state.receivedData.reserveCapacity(len + 1024)
                                }
                            }
                            
                            // Handle HEAD request
                            if state.requestPath == "/" {
                                self?.sendSuccessResponse(connection, message: "OK", keepAlive: state.keepAlive) { shouldContinue in
                                    if shouldContinue {
                                        state.reset()
                                        receiveNext()
                                    }
                                }
                                return
                            }
                            
                            // Check if path is /api/upload
                            if state.requestPath != "/api/upload" {
                                self?.sendErrorResponse(connection, statusCode: 404, message: "Not Found", keepAlive: state.keepAlive) { shouldContinue in
                                    if shouldContinue {
                                        state.reset()
                                        receiveNext()
                                    }
                                }
                                return
                            }
                            
                            // Extract body data
                            let remainingData = state.receivedData.subdata(in: bodyStart..<state.receivedData.count)
                            state.receivedData = remainingData
                            state.isHeaderComplete = true
                        }
                    } else {
                        // Receiving body
                        state.receivedData.append(data)
                        
                        // Log progress every ~5MB
                        if state.receivedData.count - state.lastLoggedSize > 5 * 1024 * 1024 {
                            if let total = state.contentLength {
                                let percent = Int(Double(state.receivedData.count) / Double(total) * 100)
                                Self.log.info("Receiving upload: \(state.receivedData.count) / \(total) bytes (\(percent)%)")
                            } else {
                                Self.log.info("Receiving upload: \(state.receivedData.count) bytes")
                            }
                            state.lastLoggedSize = state.receivedData.count
                        }
                    }
                    
                    // Check if we have the full body
                    if state.isHeaderComplete {
                        if let contentLength = state.contentLength {
                            if state.receivedData.count >= contentLength {
                                Self.log.info("Upload complete (\(state.receivedData.count) bytes). Processing...")
                                let bodyData = state.receivedData.prefix(contentLength)
                                let keepAlive = state.keepAlive
                                self?.processMultipartData(data: Data(bodyData), boundary: state.boundary, connection: connection, keepAlive: keepAlive) { shouldContinue in
                                    if shouldContinue {
                                        state.reset()
                                        receiveNext()
                                    }
                                }
                                return
                            }
                        }
                    }
                }
                
                if isComplete {
                    cancelIdleTimer()
                    if state.isHeaderComplete {
                        // If no content length was specified, or we have enough data (checked above), process it
                        if state.contentLength == nil {
                            let keepAlive = state.keepAlive
                            self?.processMultipartData(data: state.receivedData, boundary: state.boundary, connection: connection, keepAlive: keepAlive) { shouldContinue in
                                if shouldContinue {
                                    state.reset()
                                    receiveNext()
                                }
                            }
                        } else {
                            // We have content length but connection closed before we got it all
                            Self.log.error("Connection closed before full body received. Got \(state.receivedData.count), expected \(state.contentLength ?? -1)")
                            self?.sendErrorResponse(connection, statusCode: 400, message: "Incomplete body", keepAlive: false) { _ in }
                        }
                    } else {
                        connection.cancel()
                    }
                } else {
                    // Continue receiving
                    receiveNext()
                }
            }
        }
        
        receiveNext()
    }
    
    nonisolated private func parseRequestPath(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            if line.hasPrefix("POST ") || line.hasPrefix("GET ") {
                let components = line.components(separatedBy: " ")
                if components.count >= 2 {
                    return components[1]
                }
            }
        }
        return nil
    }
    
    nonisolated private func parseContentLength(from headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                return Int(value ?? "")
            }
        }
        return nil
    }
    
    nonisolated private func parseBoundary(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-type:") {
                let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                if let boundaryRange = value?.range(of: "boundary=") {
                    let boundaryValue = String(value![boundaryRange.upperBound...])
                    return "--" + boundaryValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }
    
    nonisolated private func parseKeepAlive(from headers: String) -> Bool {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("connection:") {
                let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces).lowercased()
                return value == "keep-alive"
            }
        }
        return false
    }
    
    private enum MultipartPart {
        case file(data: Data, filename: String)
        case field(name: String, value: String)
    }
    
    nonisolated private func processMultipartData(data: Data, boundary: String?, connection: NWConnection, keepAlive: Bool, completion: @escaping (Bool) -> Void) {
        guard let boundary = boundary else {
            Self.log.error("No boundary found in multipart data")
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request: No boundary", keepAlive: keepAlive, completion: completion)
            return
        }
        
        let boundaryData = boundary.data(using: .utf8)!
        let parts = splitMultipartData(data, boundary: boundaryData)
        
        var fileData: Data?
        var filename: String?
        var captureID: String?
        var parameters: [String: String] = [:]
        
        for part in parts {
            guard let parsedPart = parseMultipartPart(part) else { continue }
            
            switch parsedPart {
            case .file(let data, let partFilename):
                fileData = data
                filename = partFilename
            case .field(let name, let value):
                parameters[name] = value
            }
        }
        
        captureID = parameters["capture_id"]
        
        guard let fileData = fileData else {
            Self.log.error("No file data found in multipart request")
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request: No file", keepAlive: keepAlive, completion: completion)
            return
        }
        
        // Always save to the same filename, overwriting the previous file
        let fileURL = currentPLYFileURL
        
        do {
            // Remove old file if it exists
            try? FileManager.default.removeItem(at: fileURL)
            
            // Check if the received file is an SPZ file
            let isSPZFile = filename?.lowercased().hasSuffix(".spz") ?? false
            
            if isSPZFile {
                // Save SPZ file temporarily
                let tempSPZURL = fileURL.deletingLastPathComponent().appendingPathComponent("temp_received.spz")
                try? FileManager.default.removeItem(at: tempSPZURL)
                try fileData.write(to: tempSPZURL)
                
                Self.log.info("Received SPZ file saved to: \(tempSPZURL.path), capture_id: \(captureID ?? "none")")
                
                // Send success response immediately
                sendSuccessResponse(connection, message: "SPZ file received successfully", keepAlive: keepAlive, completion: completion)
                
                // Decompress SPZ to PLY asynchronously after response is sent
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self = self else { return }
                    
                    if self.decompressSPZToPLY(spzFileURL: tempSPZURL, outputURL: fileURL, captureID: captureID) {
                        await MainActor.run {
                            self.lastReceivedFileURL = fileURL
                            self.lastCaptureID = captureID
                            self.lastRequestParameters = parameters
                            self.onFileReceived?(fileURL, captureID)
                            NotificationCenter.default.post(name: Constants.plyReceivedNotificationName, object: nil, userInfo: ["url": fileURL])
                        }
                    }
                }
            } else {
                // Regular PLY file, save as-is
                try fileData.write(to: fileURL)
                Self.log.info("Received PLY file saved to: \(fileURL.path), capture_id: \(captureID ?? "none")")
                
                Task { @MainActor in
                    self.lastReceivedFileURL = fileURL
                    self.lastCaptureID = captureID
                    self.lastRequestParameters = parameters
                    self.onFileReceived?(fileURL, captureID)
                    NotificationCenter.default.post(name: Constants.plyReceivedNotificationName, object: nil, userInfo: ["url": fileURL])
                }
                
                // Send success response
                sendSuccessResponse(connection, message: "File received successfully", keepAlive: keepAlive, completion: completion)
            }
        } catch {
            Self.log.error("Failed to save received file: \(error.localizedDescription)")
            sendErrorResponse(connection, statusCode: 500, message: "Failed to save file", keepAlive: keepAlive, completion: completion)
        }
    }
    
    nonisolated private func splitMultipartData(_ data: Data, boundary: Data) -> [Data] {
        var parts: [Data] = []
        var currentIndex = data.startIndex
        
        while currentIndex < data.endIndex {
            // Find boundary
            if let boundaryRange = data.range(of: boundary, options: [], in: currentIndex..<data.endIndex) {
                // Extract part before boundary
                if boundaryRange.lowerBound > currentIndex {
                    let part = data.subdata(in: currentIndex..<boundaryRange.lowerBound)
                    if !part.isEmpty {
                        parts.append(part)
                    }
                }
                currentIndex = boundaryRange.upperBound
            } else {
                // No more boundaries, take remaining data
                if currentIndex < data.endIndex {
                    let part = data.subdata(in: currentIndex..<data.endIndex)
                    if !part.isEmpty {
                        parts.append(part)
                    }
                }
                break
            }
        }
        
        return parts
    }
    
    nonisolated private func parseMultipartPart(_ part: Data) -> MultipartPart? {
        // Look for header/body separator (CRLF CRLF)
        guard let separatorRange = part.range(of: "\r\n\r\n".data(using: .utf8)!) else {
            return nil
        }
        
        let headerData = part.subdata(in: part.startIndex..<separatorRange.lowerBound)
        var bodyData = part.subdata(in: separatorRange.upperBound..<part.endIndex)
        
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        
        var filename: String?
        var fieldName: String?
        
        // Parse Content-Disposition header
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-disposition:") {
                // Extract field name and filename
                if let nameRange = line.range(of: "name=\"") {
                    let afterName = String(line[nameRange.upperBound...])
                    if let nameEndRange = afterName.range(of: "\"") {
                        fieldName = String(afterName[..<nameEndRange.lowerBound])
                    }
                }
                
                if let filenameRange = line.range(of: "filename=\"") {
                    let afterFilename = String(line[filenameRange.upperBound...])
                    if let filenameEndRange = afterFilename.range(of: "\"") {
                        filename = String(afterFilename[..<filenameEndRange.lowerBound])
                    }
                }
            }
        }
        
        guard let fieldName = fieldName else {
            return nil
        }
        
        if let filename = filename {
            // Trim trailing CRLF if present (multipart form data often has trailing newlines)
            while let lastByte = bodyData.last, (lastByte == 0x0D || lastByte == 0x0A) {
                bodyData.removeLast()
            }
            return .file(data: bodyData, filename: filename)
        } else {
            let value = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .field(name: fieldName, value: value)
        }
    }
    
    nonisolated private func decompressSPZToPLY(spzFileURL: URL, outputURL: URL, captureID: String?) -> Bool {
        defer {
            // Clean up temp SPZ file after decompression
            try? FileManager.default.removeItem(at: spzFileURL)
        }
        
        let startTime = Date()
        Self.log.info("Decompressing SPZ file to PLY...")
        
        // Decompress SPZ to PLY
        let spzPath = spzFileURL.path
        let plyPath = outputURL.path
        
        // Load SPZ file
        let loadStartTime = Date()
        let cloud: SpzGaussianCloudHandle? = spzPath.withCString { spzPathPtr in
            return spz_load_spz_from_file(spzPathPtr)
        }
        let loadDuration = Date().timeIntervalSince(loadStartTime)
        
        guard let cloud = cloud else {
            Self.log.error("Failed to load SPZ file: \(spzPath)")
            return false
        }
        
        defer {
            spz_gaussian_cloud_destroy(cloud)
        }
        
        Self.log.info("SPZ file loaded in \(String(format: "%.3f", loadDuration))s")
        
        // Create pack options (optional, can be nil)
        let options = spz_pack_options_create()
        defer {
            if let options = options {
                spz_pack_options_destroy(options)
            }
        }
        
        // Save as PLY
        let saveStartTime = Date()
        let success = plyPath.withCString { plyPathPtr in
            return spz_save_splat_to_ply(cloud, options, plyPathPtr)
        }
        let saveDuration = Date().timeIntervalSince(saveStartTime)
        
        let totalDuration = Date().timeIntervalSince(startTime)
        
        if success {
            Self.log.info("SPZ file decompressed to PLY: \(plyPath), capture_id: \(captureID ?? "none")")
            Self.log.info("Decompression timing - Load: \(String(format: "%.3f", loadDuration))s, Save: \(String(format: "%.3f", saveDuration))s, Total: \(String(format: "%.3f", totalDuration))s")
            return true
        } else {
            Self.log.error("Failed to save decompressed PLY file (took \(String(format: "%.3f", totalDuration))s)")
            return false
        }
    }
    
    nonisolated private func sendSuccessResponse(_ connection: NWConnection, message: String, keepAlive: Bool, completion: @escaping (Bool) -> Void) {
        let connectionHeader = keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(message.utf8.count)\r\n\(connectionHeader)\r\n\(message)"
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error = error {
                    Self.log.error("Failed to send response: \(error.localizedDescription)")
                    connection.cancel()
                    completion(false)
                } else {
                    if keepAlive {
                        Self.log.info("Response sent, keeping connection alive for next request")
                        completion(true)
                    } else {
                        Self.log.info("Response sent, closing connection")
                        connection.cancel()
                        completion(false)
                    }
                }
            })
        } else {
            connection.cancel()
            completion(false)
        }
    }
    
    nonisolated private func sendErrorResponse(_ connection: NWConnection, statusCode: Int, message: String, keepAlive: Bool, completion: @escaping (Bool) -> Void) {
        let connectionHeader = keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        let response = "HTTP/1.1 \(statusCode) \(message)\r\nContent-Type: text/plain\r\nContent-Length: \(message.utf8.count)\r\n\(connectionHeader)\r\n\(message)"
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error = error {
                    Self.log.error("Failed to send error response: \(error.localizedDescription)")
                    connection.cancel()
                    completion(false)
                } else {
                    if keepAlive {
                        Self.log.info("Error response sent, keeping connection alive for next request")
                        completion(true)
                    } else {
                        Self.log.info("Error response sent, closing connection")
                        connection.cancel()
                        completion(false)
                    }
                }
            })
        } else {
            connection.cancel()
            completion(false)
        }
    }
    
    // MARK: - NetServiceDelegate
    
    @MainActor
    func netServiceDidPublish(_ sender: NetService) {
        localNetworkPermissionDenied = false
        Self.log.info("Bonjour service published successfully: \(sender.name)")
    }
    
    @MainActor
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        if let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue {
            // Error -72008 (kDNSServiceErr_PolicyDenied) means local network permission was denied
            if errorCode == -72008 {
                localNetworkPermissionDenied = true
                Self.log.warning("Bonjour service failed: Local network permission denied. Server will still accept direct IP connections. Please enable Local Network access in Settings > Privacy & Security > Local Network.")
            } else {
                Self.log.error("Bonjour service failed to publish with error code: \(errorCode)")
            }
        } else {
            Self.log.error("Bonjour service failed to publish: \(errorDict)")
        }
        // Continue operating even if Bonjour fails - direct IP connections will still work
    }
    
    @MainActor
    func netServiceDidStop(_ sender: NetService) {
        Self.log.info("Bonjour service stopped: \(sender.name)")
    }
}

#endif // os(visionOS)
