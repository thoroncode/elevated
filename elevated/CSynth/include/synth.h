#pragma once
#include <stdint.h>

// Total output samples (stereo pairs).  Buffer must hold ELEVATED_TOTAL_SAMPLES*2 floats.
#define ELEVATED_TOTAL_SAMPLES 9568256

// Synthesize the full Elevated soundtrack into output[0..ELEVATED_TOTAL_SAMPLES*2-1].
// Format: interleaved float32 stereo at 44100 Hz, range approx [-1, 1].
// Allocates ~380 MB internally for the synth stack; frees it before returning.
void elevated_generate_music(float *output);

// Compute instrument-sync values for 8 visual light beams.
// Exact port of the DemoEffect() instrument sync loop from demo_deb.cpp:
//   d = position; for all i: sync[i] = d;
//   scan beats 0..(position/MAX_NOTE_SAMPLES)/16 of instrument-2 sequence;
//   for each note: sync[note&7] = d (overwrites; last = earliest note in range)
// sync_out[8]: smaller values → brighter beam (used with exp(-d*0.0002))
void elevated_instrument_sync(int position, float *sync_out);
