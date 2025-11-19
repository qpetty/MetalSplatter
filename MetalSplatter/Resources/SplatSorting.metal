#include <metal_stdlib>
#include "ShaderCommon.h"

using namespace metal;

// Calculate distances for sorting
// If index >= splatCount, we write -INFINITY to distance so it sorts to the end (we sort descending)
kernel void calcSplatDistances(device float* distances [[buffer(0)]],
                               device uint* indices [[buffer(1)]],
                               constant Splat* splats [[buffer(2)]],
                               constant uint& splatCount [[buffer(3)]],
                               constant float3& cameraPosition [[buffer(4)]],
                               constant float3& cameraForward [[buffer(5)]],
                               constant bool& sortByDistance [[buffer(6)]],
                               uint gid [[thread_position_in_grid]])
{
    // We launch threads covering the padded power-of-two size
    if (gid >= splatCount) {
        distances[gid] = -INFINITY;
        indices[gid] = gid;
        return;
    }

    indices[gid] = gid;
    float3 pos = splats[gid].position;

    if (sortByDistance) {
        float3 delta = pos - cameraPosition;
        // We want to sort by distance descending.
        // Squared distance is monotonic with distance, so it preserves order.
        float dist = dot(delta, delta);
        if (isnan(dist) || isinf(dist)) {
            distances[gid] = -INFINITY;
        } else {
            distances[gid] = dist;
        }
    } else {
        // Sort by projection along forward vector
        float dist = dot(pos, cameraForward);
        if (isnan(dist) || isinf(dist)) {
            distances[gid] = -INFINITY;
        } else {
            distances[gid] = dist;
        }
    }
}

// Bitonic sort pass
// Sorts (distance, index) pairs descending based on distance
kernel void bitonicSort(device float* distances [[buffer(0)]],
                        device uint* indices [[buffer(1)]],
                        constant uint& stage [[buffer(2)]], // k in standard notation (2, 4, 8...)
                        constant uint& pass [[buffer(3)]],  // j in standard notation (k, k/2... 1)
                        uint gid [[thread_position_in_grid]])
{
    // gid is the thread index. We process one pair per thread?
    // Or we process one element per thread?
    // Let's assume we launch N/2 threads, so each thread handles one comparison.
    
    uint i = gid;
    
    // Determine the pair to compare
    // In a standard bitonic merge step with parameter 'pass' (j):
    // The partner is i ^ pass.
    // But we need to map linear thread id 'i' to the correct indices.
    // If we launch N/2 threads, we need to construct the indices.
    
    // Alternative: Launch N threads.
    // partner = gid ^ pass
    // if (partner > gid) return; // Only one thread processes the pair
    // This is easier.
    
    uint j = gid ^ pass;
    
    if (j <= gid) return; // Let the lower index handle the swap
    
    // Now we have pair (gid, j) where gid < j.
    
    float distA = distances[gid];
    float distB = distances[j];
    
    // Direction of sort:
    // In bitonic sort, direction flips every 'stage * 2' block.
    // bool ascending = (gid & stage) == 0; // This is for standard bitonic sort
    
    // However, we want the final result to be fully Descending.
    // The standard bitonic sort produces Ascending.
    // To get Descending, we invert the direction logic.
    
    bool directionDescending = (gid & stage) == 0;
    
    // If we want the whole array sorted Descending, the final merge (stage=N) should be Descending.
    // The logic (gid & stage) == 0 gives:
    // stage=2: 0,1 (Desc), 2,3 (Asc)
    // ...
    // Wait, let's verify the standard algorithm.
    // For stage k:
    //   For pass j = k/2 down to 1:
    //     compare elements.
    
    // The direction depends on the *stage*.
    // For a block of size 2*stage, the first half sorts one way, second half the other.
    // Actually, the standard algorithm builds sorted sequences of length 2, 4, 8...
    // Sequence of length 'stage' is sorted. We are merging two 'stage' sequences into '2*stage'.
    // The direction is determined by `(gid / (stage * 2)) % 2 == 0` ? No.
    
    // Let's use the standard reference:
    // for (k = 2; k <= N; k *= 2) // stage
    //   for (j = k/2; j > 0; j /= 2) // pass
    //     for (i = 0; i < N; i++)
    //       l = i ^ j
    //       if (l > i)
    //         if ( (i & k) == 0 ) // Ascending
    //           if (a[i] > a[l]) swap
    //         else // Descending
    //           if (a[i] < a[l]) swap
    
    // We want the final result (k=N) to be Descending.
    // So we want the logic to be:
    // if ( (i & stage) != 0 ) // Ascending (swapped from standard)
    // else // Descending
    
    // Wait, if we want the final array (size N) to be Descending.
    // When k=N (final stage), (i & N) is always 0 (since i < N).
    // So (i & k) == 0 condition is always true.
    // So standard algo produces Ascending.
    // To get Descending, we just flip the comparison or the direction check.
    
    // Let's flip the direction check:
    // bool sortDescending = (gid & stage) == 0;
    
    // If sortDescending:
    //   we want a[gid] >= a[j]. If a[gid] < a[j], swap.
    // If !sortDescending (Ascending):
    //   we want a[gid] <= a[j]. If a[gid] > a[j], swap.
    
    bool sortDescending = (gid & stage) == 0;
    
    bool swap = false;
    if (sortDescending) {
        if (distA < distB) swap = true;
    } else {
        if (distA > distB) swap = true;
    }
    
    if (swap) {
        distances[gid] = distB;
        distances[j] = distA;
        
        uint idxA = indices[gid];
        uint idxB = indices[j];
        indices[gid] = idxB;
        indices[j] = idxA;
    }
}

// Reorder splats based on sorted indices
kernel void reorderSplats(device Splat* outSplats [[buffer(0)]],
                          constant Splat* inSplats [[buffer(1)]],
                          constant uint* indices [[buffer(2)]],
                          constant uint& splatCount [[buffer(3)]],
                          uint gid [[thread_position_in_grid]])
{
    if (gid >= splatCount) return;
    
    uint sortedIndex = indices[gid];
    
    if (sortedIndex >= splatCount) {
        // This can happen if the sort fails (e.g. due to NaNs) or if there's a logic error.
        // We must avoid reading OOB from inSplats.
        // Use the first splat as a dummy, but make it invisible.
        outSplats[gid] = inSplats[0];
        // Set alpha to 0 to hide it. packed_half4 is (r, g, b, a)
        // We can't easily access .a directly on packed type, so assign a new value
        outSplats[gid].color = packed_half4(0.0h, 0.0h, 0.0h, 0.0h);
    } else {
        outSplats[gid] = inSplats[sortedIndex];
    }
}

