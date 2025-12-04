#if os(visionOS) || os(macOS) || os(iOS)

import Foundation
import os
import simd
import SplatIO

// SPZ C functions are exposed via the bridging header (MetalSplatter-Bridging-Header.h)

/// Helper class for loading SPZ files directly
class SPZLoader {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SPZLoader")
    
    enum LoadError: LocalizedError {
        case failedToLoadSPZ(String)
        case invalidData
        
        var errorDescription: String? {
            switch self {
            case .failedToLoadSPZ(let path):
                return "Failed to load SPZ file: \(path)"
            case .invalidData:
                return "SPZ file contains invalid data"
            }
        }
    }
    
    /// Returns true if the URL points to an SPZ file
    static func isSPZFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "spz"
    }
    
    /// Load SPZ file directly into SplatScenePoint array
    /// - Parameter url: The URL of the SPZ file to load
    /// - Returns: Array of SplatScenePoint objects
    static func loadPoints(from url: URL) throws -> [SplatScenePoint] {
        let startTime = Date()
        log.info("Loading SPZ file directly: \(url.lastPathComponent)")
        
        // Load SPZ file
        let cloud: SpzGaussianCloudHandle? = url.path.withCString { spzPathPtr in
            return spz_load_spz_from_file(spzPathPtr)
        }
        
        guard let cloud = cloud else {
            throw LoadError.failedToLoadSPZ(url.path)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        return try extractPointsFromCloud(cloud, source: url.lastPathComponent, loadDuration: duration)
    }
    
    /// Load SPZ from memory buffer directly into SplatScenePoint array
    /// - Parameter data: The SPZ data in memory
    /// - Returns: Array of SplatScenePoint objects
    static func loadPoints(from data: Data) throws -> [SplatScenePoint] {
        let startTime = Date()
        log.info("Loading SPZ from memory: \(data.count) bytes")
        
        // Load SPZ from memory
        let cloud: SpzGaussianCloudHandle? = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return spz_load_spz_from_memory(baseAddress, Int32(data.count))
        }
        
        guard let cloud = cloud else {
            throw LoadError.failedToLoadSPZ("memory buffer (\(data.count) bytes)")
        }
        
        let duration = Date().timeIntervalSince(startTime)
        return try extractPointsFromCloud(cloud, source: "memory", loadDuration: duration)
    }
    
    /// Extract SplatScenePoints from a loaded GaussianCloud
    private static func extractPointsFromCloud(_ cloud: SpzGaussianCloudHandle, source: String, loadDuration: TimeInterval) throws -> [SplatScenePoint] {
        defer {
            spz_gaussian_cloud_destroy(cloud)
        }
        
        let numPoints = Int(spz_gaussian_cloud_num_points(cloud))
        let shDegree = Int(spz_gaussian_cloud_sh_degree(cloud))
        
        guard numPoints > 0 else {
            log.warning("SPZ data contains no points")
            return []
        }
        
        guard let positions = spz_gaussian_cloud_positions(cloud),
              let scales = spz_gaussian_cloud_scales(cloud),
              let rotations = spz_gaussian_cloud_rotations(cloud),
              let alphas = spz_gaussian_cloud_alphas(cloud),
              let colors = spz_gaussian_cloud_colors(cloud) else {
            throw LoadError.invalidData
        }
        
        let shPtr = spz_gaussian_cloud_sh(cloud)
        let shCount = spz_gaussian_cloud_sh_count(cloud)
        
        // Calculate SH coefficients per point based on shDegree
        // shDegree 0 → 0, 1 → 9, 2 → 24, 3 → 45
        let shCoeffsPerPoint: Int
        switch shDegree {
        case 0: shCoeffsPerPoint = 0
        case 1: shCoeffsPerPoint = 9
        case 2: shCoeffsPerPoint = 24
        case 3: shCoeffsPerPoint = 45
        default: shCoeffsPerPoint = 0
        }
        
        log.info("SPZ: \(numPoints) points, SH degree \(shDegree) (\(shCoeffsPerPoint) coeffs/point)")
        
        var points = [SplatScenePoint]()
        points.reserveCapacity(numPoints)
        
        for i in 0..<numPoints {
            // Position: 3 floats per point
            let px = positions[i * 3 + 0]
            let py = positions[i * 3 + 1]
            let pz = positions[i * 3 + 2]
            let position = SIMD3<Float>(px, py, pz)
            
            // Scale: 3 floats per point (log scale)
            let sx = scales[i * 3 + 0]
            let sy = scales[i * 3 + 1]
            let sz = scales[i * 3 + 2]
            let scale = SplatScenePoint.Scale.exponent(SIMD3<Float>(sx, sy, sz))
            
            // Rotation: 4 floats per point (quaternion: x, y, z, w)
            let rx = rotations[i * 4 + 0]
            let ry = rotations[i * 4 + 1]
            let rz = rotations[i * 4 + 2]
            let rw = rotations[i * 4 + 3]
            // simd_quatf expects (ix, iy, iz, r) = (x, y, z, w)
            let rotation = simd_quatf(ix: rx, iy: ry, iz: rz, r: rw)
            
            // Alpha: 1 float per point (pre-sigmoid / logit)
            let alpha = alphas[i]
            let opacity = SplatScenePoint.Opacity.logitFloat(alpha)
            
            // Color: Build spherical harmonic from DC component and optional higher-order SH
            // Colors are stored as SH DC component: color = 0.5 + 0.282095 * sh0
            // We need to convert back to SH: sh0 = (color - 0.5) / 0.282095
            let cr = colors[i * 3 + 0]
            let cg = colors[i * 3 + 1]
            let cb = colors[i * 3 + 2]
            
            // The colors array already contains the SH DC coefficients (f_dc_0, f_dc_1, f_dc_2)
            // which are the raw SH values before the color transform
            let sh0 = SIMD3<Float>(cr, cg, cb)
            
            var shCoeffs: [SIMD3<Float>] = [sh0]
            
            // Add higher-order SH coefficients if available
            if shCoeffsPerPoint > 0, let shPtr = shPtr, shCount > 0 {
                // SH coefficients are stored interleaved by channel: r, g, b, r, g, b, ...
                // For each additional SH basis function
                let numAdditionalCoeffs = shCoeffsPerPoint / 3  // 3, 8, or 15 additional basis functions
                let shOffset = i * shCoeffsPerPoint
                
                for j in 0..<numAdditionalCoeffs {
                    let idx = shOffset + j * 3
                    if idx + 2 < shCount {
                        let shR = shPtr[idx + 0]
                        let shG = shPtr[idx + 1]
                        let shB = shPtr[idx + 2]
                        shCoeffs.append(SIMD3<Float>(shR, shG, shB))
                    }
                }
            }
            
            let color = SplatScenePoint.Color.sphericalHarmonic(shCoeffs)
            
            let point = SplatScenePoint(
                position: position,
                color: color,
                opacity: opacity,
                scale: scale,
                rotation: rotation
            )
            points.append(point)
        }
        
        let totalDuration = loadDuration
        log.info("SPZ loaded from \(source) in \(String(format: "%.3f", totalDuration))s (\(numPoints) points)")
        
        return points
    }
}

/// Scene reader for SPZ files that implements SplatSceneReader protocol
class SPZSceneReader: SplatSceneReader {
    private let url: URL
    
    init(_ url: URL) {
        self.url = url
    }
    
    func read(to delegate: SplatSceneReaderDelegate) {
        do {
            let points = try SPZLoader.loadPoints(from: url)
            delegate.didStartReading(withPointCount: UInt32(points.count))
            delegate.didRead(points: points)
            delegate.didFinishReading()
        } catch {
            delegate.didFailReading(withError: error)
        }
    }
}

#endif // os(visionOS) || os(macOS) || os(iOS)
