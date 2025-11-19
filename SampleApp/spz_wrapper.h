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

// Optional: Get last error message (useful for debugging)
const char* spz_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* SpzWrapper_h */
