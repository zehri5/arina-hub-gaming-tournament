// HOST-ONLY — NOT PART OF THE SHIPPED CODE. See reverb_host_test.cpp.
//
// Probes the latent defect: FreeverbProcessor::process() on a processor
// that was never configure()d. The comb/allpass buffers are empty, so
// CombFilter::process() indexes buffer_[0] on an empty vector (UB).
// Pre-fix this may segfault or corrupt memory; post-fix it must be a
// safe dry passthrough. Kept as a separate binary so a pre-fix crash
// does not kill the main harness report.
//
//   g++ -std=c++17 -O2 -Wall -Wextra -I.. -o /tmp/unconfigured_test
//       unconfigured_test.cpp ../dsp_engine.cpp

#include <cmath>
#include <cstdio>
#include <vector>

#include "dsp_engine.h"

int main() {
    arena_dsp::FreeverbProcessor rv;  // NOTE: configure() deliberately NOT called.
    rv.setParams(true, 0.5f, 0.7f, 0.3f);
    std::vector<float> buf(4800 * 2);
    for (size_t i = 0; i < buf.size(); ++i) buf[i] = 0.5f;
    rv.process(buf.data(), 4800, 2);  // must not crash
    bool passthrough = true;
    for (float v : buf) passthrough &= (v == 0.5f);
    bool finite = true;
    for (float v : buf) finite &= std::isfinite(v);
    std::printf("unconfigured process(): survived, finite=%d, dry-passthrough=%d\n",
                static_cast<int>(finite), static_cast<int>(passthrough));
    return (finite && passthrough) ? 0 : 1;
}
