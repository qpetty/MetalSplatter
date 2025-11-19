//
//  spz_wrapper.cc
//  MetalSplatter SampleApp
//
//  Created by Quinton on 11/19/25.
//

// SpzWrapper.cpp
#include "spz_wrapper.h"
#include "load-spz.h"
#include <string>

using namespace spz;

extern "C" {

// PackOptions wrapper
SpzPackOptionsHandle spz_pack_options_create() {
    return reinterpret_cast<SpzPackOptionsHandle>(new PackOptions());
}

void spz_pack_options_destroy(SpzPackOptionsHandle opts) {
    delete reinterpret_cast<PackOptions*>(opts);
}

void spz_pack_options_set_from_coord(SpzPackOptionsHandle opts, SpzCoordinateSystem system) {
    auto* o = reinterpret_cast<PackOptions*>(opts);
    switch (system) {
        case SpzCoordinateSystem_RDF:      o->from = CoordinateSystem::RDF; break;
        case SpzCoordinateSystem_OPENGL:   o->from = CoordinateSystem::LUF; break;
        case SpzCoordinateSystem_OPENCV:   o->from = CoordinateSystem::RDF; break;
        default:                           o->from = CoordinateSystem::UNSPECIFIED; break;
    }
}

// Main functions
SpzGaussianCloudHandle spz_load_spz_from_file(const char* filename) {
    try {
        UnpackOptions opts;
        opts.to = CoordinateSystem::UNSPECIFIED; // keep original
        GaussianCloud cloud = loadSpz(std::string(filename), opts);
        return reinterpret_cast<SpzGaussianCloudHandle>(new GaussianCloud(std::move(cloud)));
    } catch (const std::exception& e) {
        // You could store last error globally if you want
        return nullptr;
    }
}

bool spz_save_splat_to_ply(
    SpzGaussianCloudHandle cloud,
    SpzPackOptionsHandle   options,
    const char*            output_ply_path)
{
    if (!cloud || !output_ply_path) return false;

    try {
        const auto& c = *reinterpret_cast<const GaussianCloud*>(cloud);
        const auto& o = options ? *reinterpret_cast<const PackOptions*>(options)
                               : PackOptions{};
        return saveSplatToPly(c, o, std::string(output_ply_path));
    } catch (...) {
        return false;
    }
}

void spz_gaussian_cloud_destroy(SpzGaussianCloudHandle cloud) {
    delete reinterpret_cast<GaussianCloud*>(cloud);
}

const char* spz_get_last_error(void) {
    // Optional: implement thread-local last error storage
    return "No error";
}

} // extern "C"
