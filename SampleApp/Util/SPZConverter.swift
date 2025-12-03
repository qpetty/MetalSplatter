#if os(visionOS) || os(macOS)

import Foundation
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

/// Helper class for converting SPZ files to PLY format
class SPZConverter {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SPZConverter")
    
    enum ConversionError: LocalizedError {
        case failedToLoadSPZ(String)
        case failedToSavePLY(String)
        case temporaryDirectoryError
        
        var errorDescription: String? {
            switch self {
            case .failedToLoadSPZ(let path):
                return "Failed to load SPZ file: \(path)"
            case .failedToSavePLY(let path):
                return "Failed to save PLY file: \(path)"
            case .temporaryDirectoryError:
                return "Failed to create temporary directory for conversion"
            }
        }
    }
    
    /// Returns true if the URL points to an SPZ file
    static func isSPZFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "spz"
    }
    
    /// Converts an SPZ file to PLY format
    /// - Parameter spzURL: The URL of the SPZ file to convert
    /// - Returns: The URL of the converted PLY file (in a temporary location)
    static func convertToPLY(_ spzURL: URL) throws -> URL {
        let startTime = Date()
        log.info("Converting SPZ file to PLY: \(spzURL.lastPathComponent)")
        
        // Create temporary directory for converted files
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPZConversion", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Create output PLY path with same base name
        let baseName = spzURL.deletingPathExtension().lastPathComponent
        let outputURL = tempDirectory.appendingPathComponent("\(baseName).ply")
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Load SPZ file
        let loadStartTime = Date()
        let cloud: UnsafeMutableRawPointer? = spzURL.path.withCString { spzPathPtr in
            return spz_load_spz_from_file(spzPathPtr)
        }
        let loadDuration = Date().timeIntervalSince(loadStartTime)
        
        guard let cloud = cloud else {
            throw ConversionError.failedToLoadSPZ(spzURL.path)
        }
        
        defer {
            spz_gaussian_cloud_destroy(cloud)
        }
        
        log.info("SPZ file loaded in \(String(format: "%.3f", loadDuration))s")
        
        // Create pack options
        let options = spz_pack_options_create()
        defer {
            if let options = options {
                spz_pack_options_destroy(options)
            }
        }
        
        // Save as PLY
        let saveStartTime = Date()
        let success = outputURL.path.withCString { plyPathPtr in
            return spz_save_splat_to_ply(cloud, options, plyPathPtr)
        }
        let saveDuration = Date().timeIntervalSince(saveStartTime)
        
        let totalDuration = Date().timeIntervalSince(startTime)
        
        guard success else {
            throw ConversionError.failedToSavePLY(outputURL.path)
        }
        
        log.info("SPZ to PLY conversion complete - Load: \(String(format: "%.3f", loadDuration))s, Save: \(String(format: "%.3f", saveDuration))s, Total: \(String(format: "%.3f", totalDuration))s")
        
        return outputURL
    }
    
    /// Converts SPZ to PLY if needed, otherwise returns the original URL
    /// - Parameter url: The URL of the file to potentially convert
    /// - Returns: The URL to use for loading (either original or converted)
    static func convertIfNeeded(_ url: URL) throws -> URL {
        if isSPZFile(url) {
            return try convertToPLY(url)
        }
        return url
    }
}

#endif // os(visionOS) || os(macOS)

