import SwiftUI
import RealityKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false
    @AppStorage("enableFileMonitoring") private var enableFileMonitoring = true

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
    
    private func reloadStreamingModel() async {
        // Force reload by dismissing and reopening the immersive space
        // This ensures the file is reloaded even though the URL is the same
        guard let currentModel = currentStreamingModelIdentifier else { return }
        
        // Always dismiss first (safe even if not shown)
        await dismissImmersiveSpace()
        immersiveSpaceIsShown = false
        // Small delay to ensure dismissal completes
        try? await Task.sleep(for: .milliseconds(100))
        
        // Reopen with the same model (file content has changed)
        openWindow(value: currentModel)
    }
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
                      ]) {
            isPickingFile = false
            switch $0 {
            case .success(let url):
                _ = url.startAccessingSecurityScopedResource()
                Task {
                    // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                    try await Task.sleep(for: .seconds(10))
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

#if os(visionOS)
        Button("Start Streaming Mode") {
            isStreamingMode = true
            streamingServer.start()
            
            // Set up file received handler
            streamingServer.onFileReceived = { url, captureID in
                Task { @MainActor in
                    let modelIdentifier = ModelIdentifier.gaussianSplat(url)
                    currentStreamingModelIdentifier = modelIdentifier
                    
                    // Always reload - reloadStreamingModel handles the state check
                    await reloadStreamingModel()
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
