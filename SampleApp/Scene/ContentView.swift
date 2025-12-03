import SwiftUI
import RealityKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false
    @AppStorage("enableFileMonitoring") private var enableFileMonitoring = true
    
    // WebSocket streaming state (shared across platforms)
    @StateObject private var wsClient = WebSocketStreamingClient()
    @AppStorage("wsHostAddress") private var wsHostAddress = ""
    @AppStorage("wsPort") private var wsPort = String(Constants.defaultWebSocketPort)
    @State private var isWsStreamingMode = false

#if os(visionOS)
    @StateObject private var streamingServer = PLYStreamingServer()
    @State private var isStreamingMode = false
    @State private var currentStreamingModelIdentifier: ModelIdentifier?
#endif

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false

    private func openWindow(value: ModelIdentifier) {
        Task {
            switch await openImmersiveSpace(value: value) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }
    
    
    // private func reloadStreamingModel() async { ... } // Removed as we now use in-place updates
#endif

    var body: some View {
#if os(macOS) || os(visionOS)
        mainView
#elseif os(iOS)
        NavigationStack(path: $navigationPath) {
            mainView
                .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    MetalKitSceneView(modelIdentifier: modelIdentifier)
                        .navigationTitle(modelIdentifier.description)
                }
        }
#endif // os(iOS)
    }

    @ViewBuilder
    var mainView: some View {
        VStack {
            Spacer()

            Text("MetalSplatter SampleApp")

            Spacer()

#if os(visionOS)
            if isStreamingMode {
                streamingModeView
            } else {
                normalModeView
            }
#else
            normalModeView
#endif

            Spacer()
        }
    }
    
    @ViewBuilder
    private var normalModeView: some View {
        Button("Read Scene File") {
            isPickingFile = true
        }
        .padding()
        .buttonStyle(.borderedProminent)
        .disabled(isPickingFile)
#if os(visionOS)
        .disabled(immersiveSpaceIsShown)
#endif
        .fileImporter(isPresented: $isPickingFile,
                      allowedContentTypes: [
                        UTType(filenameExtension: "ply")!,
                        UTType(filenameExtension: "splat")!,
                        UTType(filenameExtension: "spz")!,
                      ]) {
            isPickingFile = false
            switch $0 {
            case .success(let url):
                _ = url.startAccessingSecurityScopedResource()
                Task {
                    // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                    try await Task.sleep(for: .seconds(1))
                    url.stopAccessingSecurityScopedResource()
                }
                openWindow(value: ModelIdentifier.gaussianSplat(url))
            case .failure:
                break
            }
        }

        Spacer()

        Button("Show Sample Box") {
            openWindow(value: ModelIdentifier.sampleBox)
        }
        .padding()
        .buttonStyle(.borderedProminent)
#if os(visionOS)
        .disabled(immersiveSpaceIsShown)
#endif

        Spacer()

        Toggle("Enable File Monitoring", isOn: $enableFileMonitoring)
            .padding()
#if os(macOS)
            .toggleStyle(.checkbox)
#endif

        Spacer()
        
        // WebSocket Streaming Section
        wsStreamingSection

        Spacer()

#if os(visionOS)
        Button("Start Streaming Mode") {
            isStreamingMode = true
            streamingServer.start()
            
            // Open immersive space immediately in streaming mode
            openWindow(value: .streaming)
            
            // Set up file received handler
            streamingServer.onFileReceived = { url, captureID in
                Task { @MainActor in
                    let modelIdentifier = ModelIdentifier.gaussianSplat(url)
                    currentStreamingModelIdentifier = modelIdentifier
                    
                    // We no longer need to force reload the immersive space.
                    // VisionSceneRenderer listens for the notification and updates the model in-place.
                }
            }
        }
        .padding()
        .buttonStyle(.borderedProminent)
        .disabled(immersiveSpaceIsShown || isStreamingMode)
        
        Spacer()
        
        Button("Dismiss Immersive Space") {
            Task {
                await dismissImmersiveSpace()
                immersiveSpaceIsShown = false
            }
        }
        .disabled(!immersiveSpaceIsShown)

        Spacer()
#endif // os(visionOS)
    }
    
    // MARK: - WebSocket Streaming Section
    
    @ViewBuilder
    private var wsStreamingSection: some View {
        VStack(spacing: 10) {
            Text("WebSocket Streaming")
                .font(.headline)
            
            if isWsStreamingMode {
                wsStreamingActiveView
            } else {
                wsStreamingConnectView
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var wsStreamingConnectView: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Host/IP", text: $wsHostAddress)
                    .textFieldStyle(.roundedBorder)
#if os(macOS)
                    .frame(width: 150)
#endif
                
                TextField("Port", text: $wsPort)
                    .textFieldStyle(.roundedBorder)
#if os(macOS)
                    .frame(width: 60)
#endif
            }
            
            Button("Connect to Stream") {
                startWsStreaming()
            }
            .buttonStyle(.borderedProminent)
            .disabled(wsHostAddress.isEmpty)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
        }
    }
    
    @ViewBuilder
    private var wsStreamingActiveView: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(wsClient.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(wsClient.isConnected ? "Connected" : "Disconnected")
                    .foregroundColor(wsClient.isConnected ? .green : .red)
            }
            
            if wsClient.isConnected {
                Text("Server: \(wsClient.serverInfo?.format.uppercased() ?? "unknown") format")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Frames: \(wsClient.framesReceived) | Received: \(formatBytes(wsClient.bytesReceived))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Button(wsClient.isPaused ? "Resume" : "Pause") {
                        if wsClient.isPaused {
                            wsClient.resume()
                        } else {
                            wsClient.pause()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if let error = wsClient.connectionError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button("Disconnect") {
                stopWsStreaming()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
    
    private func startWsStreaming() {
        let port = Int(wsPort) ?? Constants.defaultWebSocketPort
        
        // Set up frame received handler
        wsClient.onFrameReceived = { frame in
            // Post notification with frame data
            NotificationCenter.default.post(
                name: Constants.wsFrameReceivedNotificationName,
                object: nil,
                userInfo: ["frame": frame]
            )
        }
        
        wsClient.connect(host: wsHostAddress, port: port)
        isWsStreamingMode = true
        
        // Open window/immersive space for streaming
        openWindow(value: ModelIdentifier.streaming)
    }
    
    private func stopWsStreaming() {
        wsClient.disconnect()
        isWsStreamingMode = false
#if os(visionOS)
        if immersiveSpaceIsShown {
            Task {
                await dismissImmersiveSpace()
                immersiveSpaceIsShown = false
            }
        }
#endif
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }

#if os(visionOS)
    @ViewBuilder
    private var streamingModeView: some View {
        VStack(spacing: 20) {
            Text("Streaming Mode")
                .font(.title)
                .padding()
            
            if streamingServer.isRunning {
                VStack(spacing: 10) {
                    Text("Server is running")
                        .foregroundColor(.green)
                    
                    if streamingServer.localNetworkPermissionDenied {
                        VStack(spacing: 5) {
                            Text("⚠️ Local Network Permission Required")
                                .font(.headline)
                                .foregroundColor(.orange)
                            
                            Text("Please enable Local Network access in:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Settings > Privacy & Security > Local Network > MetalSplatter")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            
                            Text("Direct IP connections may still work.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Text("Local IP Address:")
                        .font(.headline)
                    
                    Text(streamingServer.localIPAddress)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    
                    Text("Send PLY files to:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("http://\(streamingServer.localIPAddress)/api/upload")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                }
                .padding()
            } else {
                Text("Starting server...")
                    .foregroundColor(.orange)
            }
            
            if let captureID = streamingServer.lastCaptureID {
                Text("Last Capture ID: \(captureID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !streamingServer.lastRequestParameters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Request Parameters")
                        .font(.headline)
                    
                    ForEach(streamingServer.lastRequestParameters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack {
                            Text("\(key):")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            Button("Stop Streaming Mode") {
                streamingServer.stop()
                isStreamingMode = false
                currentStreamingModelIdentifier = nil
                if immersiveSpaceIsShown {
                    Task {
                        await dismissImmersiveSpace()
                        immersiveSpaceIsShown = false
                    }
                }
            }
            .padding()
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
#endif
}
