//
//  spz.h
//  MetalSplatter SampleApp
//
//  Created by Quinton on 11/19/25.
//

#ifndef SpzWrapper_h
#define SpzWrapper_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles – Swift only sees these as void*
typedef struct SpzGaussianCloud* SpzGaussianCloudHandle;
typedef struct SpzPackOptions*   SpzPackOptionsHandle;

// Coordinate system enum (mirrors spz::CoordinateSystem)
typedef enum {
    SpzCoordinateSystem_UNSPECIFIED = 0,
    SpzCoordinateSystem_RDF         = 1,
    SpzCoordinateSystem_OPENGL      = 2,
    SpzCoordinateSystem_OPENCV      = 3,
    // Add more if needed in the future
} SpzCoordinateSystem;

// === PackOptions ===

SpzPackOptionsHandle spz_pack_options_create();
void                 spz_pack_options_destroy(SpzPackOptionsHandle opts);

// Optional: set the source coordinate system (useful for correct export)
void                 spz_pack_options_set_from_coord(
                        SpzPackOptionsHandle opts,
                        SpzCoordinateSystem system);

// === Main Functions ===

// Load .spz file → GaussianCloud
// Returns NULL on failure (check last error if needed)
SpzGaussianCloudHandle spz_load_spz_from_file(const char* filename);

// Save GaussianCloud → .ply file using given options
// Returns true on success
bool spz_save_splat_to_ply(
    SpzGaussianCloudHandle cloud,
    SpzPackOptionsHandle   options,
    const char*            output_ply_path);

// Clean up the cloud when done
void spz_gaussian_cloud_destroy(SpzGaussianCloudHandle cloud);

// === Accessors for GaussianCloud data ===

// Get number of points in the cloud
int32_t spz_gaussian_cloud_num_points(SpzGaussianCloudHandle cloud);

// Get SH degree
int32_t spz_gaussian_cloud_sh_degree(SpzGaussianCloudHandle cloud);

// Get raw data pointers (data is owned by the cloud, do not free)
// Positions: 3 floats per point (x, y, z)
const float* spz_gaussian_cloud_positions(SpzGaussianCloudHandle cloud);
// Scales: 3 floats per point (log scale)
const float* spz_gaussian_cloud_scales(SpzGaussianCloudHandle cloud);
// Rotations: 4 floats per point (quaternion: x, y, z, w)
const float* spz_gaussian_cloud_rotations(SpzGaussianCloudHandle cloud);
// Alphas: 1 float per point (pre-sigmoid)
const float* spz_gaussian_cloud_alphas(SpzGaussianCloudHandle cloud);
// Colors: 3 floats per point (SH DC component)
const float* spz_gaussian_cloud_colors(SpzGaussianCloudHandle cloud);
// SH: variable floats per point depending on shDegree
const float* spz_gaussian_cloud_sh(SpzGaussianCloudHandle cloud);
// Size of SH array
size_t spz_gaussian_cloud_sh_count(SpzGaussianCloudHandle cloud);

// Optional: Get last error message (useful for debugging)
const char* spz_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* SpzWrapper_h */
