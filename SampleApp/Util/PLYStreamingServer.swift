#if os(visionOS)

import Foundation
import Network
import os

// Swift wrapper for SPZ C functions
@_silgen_name("spz_load_spz_from_file")
func spz_load_spz_from_file(_ filename: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

@_silgen_name("spz_save_splat_to_ply")
func spz_save_splat_to_ply(_ cloud: UnsafeMutableRawPointer?, _ options: UnsafeMutableRawPointer?, _ outputPath: UnsafePointer<CChar>) -> Bool

@_silgen_name("spz_gaussian_cloud_destroy")
func spz_gaussian_cloud_destroy(_ cloud: UnsafeMutableRawPointer?)

@_silgen_name("spz_pack_options_create")
func spz_pack_options_create() -> UnsafeMutableRawPointer?

@_silgen_name("spz_pack_options_destroy")
func spz_pack_options_destroy(_ options: UnsafeMutableRawPointer?)

class PLYStreamingServer: NSObject, ObservableObject, NetServiceDelegate {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "PLYStreamingServer")
    
    @MainActor @Published var isRunning = false
    @MainActor @Published var localIPAddress: String = "Not available"
    @MainActor @Published var lastReceivedFileURL: URL?
    @MainActor @Published var lastCaptureID: String?
    @MainActor @Published var localNetworkPermissionDenied: Bool = false
    
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
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
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
        }
        
        let state = ConnectionState()
        
        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let error = error {
                    Self.log.error("Connection error: \(error.localizedDescription)")
                    self?.sendErrorResponse(connection, statusCode: 500, message: "Internal Server Error")
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
                                Self.log.info("Request: \(state.requestPath ?? "nil"), Content-Length: \(state.contentLength ?? -1)")
                            }
                            
                            // Check if path is /api/upload
                            if state.requestPath != "/api/upload" {
                                self?.sendErrorResponse(connection, statusCode: 404, message: "Not Found")
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
                    }
                    
                    // Check if we have the full body
                    if state.isHeaderComplete {
                        if let contentLength = state.contentLength {
                            if state.receivedData.count >= contentLength {
                                let bodyData = state.receivedData.prefix(contentLength)
                                self?.processMultipartData(data: Data(bodyData), boundary: state.boundary, connection: connection)
                                return
                            }
                        }
                    }
                }
                
                if isComplete {
                    if state.isHeaderComplete {
                        // If no content length was specified, or we have enough data (checked above), process it
                        if state.contentLength == nil {
                            self?.processMultipartData(data: state.receivedData, boundary: state.boundary, connection: connection)
                        } else {
                            // We have content length but connection closed before we got it all
                            self?.sendErrorResponse(connection, statusCode: 400, message: "Incomplete body")
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
    
    nonisolated private func processMultipartData(data: Data, boundary: String?, connection: NWConnection) {
        guard let boundary = boundary else {
            Self.log.error("No boundary found in multipart data")
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request: No boundary")
            return
        }
        
        let boundaryData = boundary.data(using: .utf8)!
        let parts = splitMultipartData(data, boundary: boundaryData)
        
        var fileData: Data?
        var filename: String?
        var captureID: String?
        
        for part in parts {
            if let (partFileData, partFilename, partCaptureID) = parseMultipartPart(part) {
                if partFileData != nil {
                    fileData = partFileData
                    filename = partFilename
                }
                if let id = partCaptureID {
                    captureID = id
                }
            }
        }
        
        guard let fileData = fileData else {
            Self.log.error("No file data found in multipart request")
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request: No file")
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
                sendSuccessResponse(connection, message: "SPZ file received successfully")
                
                // Decompress SPZ to PLY asynchronously after response is sent
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self = self else { return }
                    
                    if self.decompressSPZToPLY(spzFileURL: tempSPZURL, outputURL: fileURL, captureID: captureID) {
                        await MainActor.run {
                            self.lastReceivedFileURL = fileURL
                            self.lastCaptureID = captureID
                            self.onFileReceived?(fileURL, captureID)
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
                    self.onFileReceived?(fileURL, captureID)
                }
                
                // Send success response
                sendSuccessResponse(connection, message: "File received successfully")
            }
        } catch {
            Self.log.error("Failed to save received file: \(error.localizedDescription)")
            sendErrorResponse(connection, statusCode: 500, message: "Failed to save file")
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
    
    nonisolated private func parseMultipartPart(_ part: Data) -> (Data?, String?, String?)? {
        // Look for header/body separator (CRLF CRLF)
        guard let separatorRange = part.range(of: "\r\n\r\n".data(using: .utf8)!) else {
            return nil
        }
        
        let headerData = part.subdata(in: part.startIndex..<separatorRange.lowerBound)
        let bodyData = part.subdata(in: separatorRange.upperBound..<part.endIndex)
        
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        
        var filename: String?
        var fieldName: String?
        var captureID: String?
        
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
        
        // If this is the file field, return file data
        if fieldName == "file" && filename != nil {
            // Trim trailing CRLF if present (multipart form data often has trailing newlines)
            var trimmedData = bodyData
            while trimmedData.count > 0 && (trimmedData.last == 0x0D || trimmedData.last == 0x0A) {
                trimmedData = trimmedData.dropLast()
            }
            return (trimmedData, filename, nil)
        }
        
        // If this is the capture_id field, extract the value
        if fieldName == "capture_id" {
            if let bodyString = String(data: bodyData, encoding: .utf8) {
                captureID = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (nil, nil, captureID) // Return capture_id
        }
        
        return nil
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
        let cloud: UnsafeMutableRawPointer? = spzPath.withCString { spzPathPtr in
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
    
    nonisolated private func sendSuccessResponse(_ connection: NWConnection, message: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)"
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    nonisolated private func sendErrorResponse(_ connection: NWConnection, statusCode: Int, message: String) {
        let response = "HTTP/1.1 \(statusCode) \(message)\r\nContent-Type: text/plain\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)"
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
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

