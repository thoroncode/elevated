#pragma once
#include <stdint.h>

// Total output samples (stereo pairs).  Buffer must hold ELEVATED_TOTAL_SAMPLES*2 floats.
#define ELEVATED_TOTAL_SAMPLES 9568256

// Synthesize the full Elevated soundtrack into output[0..ELEVATED_TOTAL_SAMPLES*2-1].
// Format: interleaved float32 stereo at 44100 Hz, range approx [-1, 1].
// Allocates ~380 MB internally for the synth stack; frees it before returning.
void elevated_generate_music(float *output);
