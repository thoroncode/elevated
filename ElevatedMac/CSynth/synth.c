/*
 * synth.c  —  C port of the Elevated (rgba/tbc, 2009) synthesizer.
 *
 * Source: ~/Downloads/mtt_iq_Elevated/ (MIT-licensed release by iq/Puryx/Mentor)
 * Ported from: src/synth.asm + src/synth_core.nh + src/music.asm
 *
 * Goal: perceptually correct output (not bit-perfect).
 * Float precision drift vs. x87 80-bit is acceptable.
 */

#include "synth.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <Accelerate/Accelerate.h>

/* ── constants ─────────────────────────────────────────────────────────────── */
#define TOTAL_SAMPLES     9568256   /* ((9503040+65535) & ~0xFFFF) */
#define STACK_SAMPLES     TOTAL_SAMPLES
#define STACK_FLOATS      ((size_t)STACK_SAMPLES * 2)  /* stereo pairs */
#define NUM_ROWS          114
#define MAX_DELAY_SAMPLES 65536
#define MAX_NOTE_SAMPLES  5210
#define INSTRUMENT_SIZE   72        /* (9 + 3*3) * 4 bytes */
#define MAX_STACK_HEIGHT  4

static const float NOTE_FREQ_START  = 1.749869973e-4f;   /* C--5 / 44100 */
static const float NOTE_FREQ_STEP   = 1.029302237f;       /* 2^(1/24)     */
static const float CUTOFF_SCALE     = 3.561896433e-5f;    /* pi/(2*44100) */
static const float RAND_SCALE       = 3.0517578125e-5f;   /* 1/32768      */

static const float ENV_NORMAL[4] = { 1.0f, -0.5f, 0.0f, -0.5f };
static const float ENV_STOP[4]   = { 0.0f,  0.0f, 0.0f,  0.0f };

/* ── LCG random (matches x86 asm exactly) ───────────────────────────────── */
static uint32_t rng_seed = 0;
static float frandom(void) {
    rng_seed = rng_seed * 16307u + 17u;
    int16_t v = (int16_t)(rng_seed >> 14);  /* signed 16-bit, then * 1/32768 */
    return v * RAND_SCALE;
}

/* ── Fast sin(pi*x) for x in [-1,1], 9th-order Taylor in Horner form ────── */
/* Max error ~0.006 near x=±1 (sin→0 there anyway). Fine for audio. */
static __attribute__((always_inline)) float fast_sinpif(float x) {
    float u  = 3.14159265f * x;
    float u2 = u * u;
    float r  = 2.75573e-6f;
    r = r * u2 - 1.98413e-4f;
    r = r * u2 + 8.33333e-3f;
    r = r * u2 - 1.66667e-1f;
    return u * (r * u2 + 1.0f);
}

/* ── Oscillator (saw / square / sine) ───────────────────────────────────── */
static __attribute__((always_inline))
float osc_wave(float phase, float phase_shift, uint8_t type) {
    float p = phase + phase_shift;
    /* round to nearest: x - floor(x+0.5) — avoids FP-mode-switching roundf */
    p = 2.0f * (p - floorf(p + 0.5f));   /* [-1, 1] */
    if (type == 1) return fast_sinpif(p);
    if (type == 2) return (p >= 0.0f) ? 1.0f : -1.0f;
    return p;   /* saw */
}

/* ────────────────────────────────────────────────────────────────────────── */
/* Music data  (verbatim from src/music.asm)                                  */
/* ────────────────────────────────────────────────────────────────────────── */

/* NOTE: pattern_data, sequence_data, machine_tree_data are copied verbatim
 * from src/music.asm (MIT-licensed source by iq/Puryx/Mentor).           */
static const uint8_t pattern_data[] = {
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,61,0,0,0,0,0,0,0,61,0,0,0,
0,0,61,0,0,0,0,0,61,127,61,127,0,0,0,0,60,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
67,0,0,0,0,0,0,0,70,0,74,0,0,0,79,0,0,0,0,0,77,0,0,0,74,0,0,0,70,0,0,0,
67,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,65,0,0,0,0,0,0,0,67,0,72,0,0,0,82,0,
0,0,0,0,81,0,0,0,77,0,0,0,70,0,0,0,60,0,0,0,0,0,0,0,70,0,74,0,0,0,75,0,
0,0,0,0,77,0,0,0,79,0,0,0,70,0,0,0,70,0,0,0,0,0,0,0,72,0,74,0,0,0,77,0,
0,0,0,0,75,0,0,0,77,0,0,0,72,0,0,0,0,0,0,0,82,0,0,0,81,0,0,0,74,0,0,0,
65,0,0,0,0,0,0,0,72,0,77,0,0,0,84,0,0,0,0,0,82,0,0,0,79,0,0,0,74,0,0,0,
60,0,0,0,0,0,0,0,65,0,69,0,0,0,70,0,0,0,0,0,72,0,0,0,70,0,0,0,69,0,0,0,
67,0,0,0,0,0,0,0,72,0,74,0,0,0,77,0,0,0,0,0,79,0,0,0,75,0,0,0,72,0,0,0,
63,0,0,0,0,0,0,0,63,0,63,0,0,0,0,0,63,0,0,0,0,0,63,0,0,0,63,0,0,0,0,0,
0,0,43,0,55,0,43,0,55,0,0,0,43,0,0,0,43,0,55,0,0,0,43,0,0,0,43,0,55,0,43,0,
0,0,41,0,53,0,41,0,53,0,0,0,41,0,0,0,41,0,53,0,0,0,41,0,0,0,41,0,53,0,41,0,
0,0,36,0,48,0,36,0,48,0,0,0,36,0,0,0,36,0,48,0,0,0,36,0,0,0,36,0,48,0,36,0,
0,0,46,0,58,0,46,0,58,0,0,0,46,0,0,0,46,0,58,0,0,0,46,0,0,0,46,0,58,0,46,0,
0,0,39,0,51,0,39,0,51,0,0,0,39,0,0,0,39,0,51,0,0,0,39,0,0,0,39,0,51,0,39,0,
0,0,38,0,50,0,38,0,50,0,0,0,38,0,0,0,38,0,50,0,0,0,38,0,0,0,38,0,50,0,38,0,
58,0,0,0,0,0,0,0,0,0,0,0,57,0,60,0,62,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
60,0,0,0,0,0,0,0,65,0,0,0,0,0,0,0,58,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,55,0,0,0,0,0,0,0,57,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
55,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,57,0,0,0,0,0,0,0,58,0,0,0,0,0,0,0,
0,0,0,0,55,0,0,0,60,0,0,0,58,0,0,0,0,0,0,0,0,0,0,0,60,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,65,0,0,0,0,0,0,0,60,0,0,0,0,0,0,0,58,0,0,0,0,0,0,0,
57,0,0,0,0,0,0,0,62,0,0,0,0,0,0,0,63,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
65,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
43,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,39,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
36,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,41,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
69,0,0,0,0,0,0,0,70,0,0,0,0,0,0,0,0,0,0,0,67,0,0,0,72,0,0,0,70,0,0,0,
0,0,0,0,0,0,0,0,72,0,0,0,0,0,0,0,74,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,77,0,0,0,0,0,0,0,72,0,0,0,0,0,0,0,70,0,0,0,0,0,0,0,
69,0,0,0,0,0,0,0,74,0,0,0,0,0,0,0,31,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
50,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,31,127,31,127,
61,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,57,0,60,0,
27,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,29,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
34,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,38,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
};

static const uint8_t sequence_data[] = {
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,
0,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,
1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,3,0,0,0,0,
0,0,0,3,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,0,3,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,5,4,5,4,5,6,4,5,7,8,9,10,11,12,4,5,7,
8,9,10,11,12,4,5,4,5,9,10,7,8,0,0,0,0,0,0,0,0,0,4,13,14,15,16,17,18,19,4,13,
14,15,9,10,11,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,4,5,6,4,5,7,8,9,10,11,12,4,5,7,8,9,10,11,12,4,5,4,5,9,10,7,8,0,
0,0,0,0,0,0,0,0,4,13,14,15,16,17,18,19,4,13,14,15,9,10,11,12,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,20,21,20,21,20,21,0,20,21,20,21,20,21,20,
21,20,21,20,21,20,21,20,21,20,21,20,21,20,21,20,20,3,0,0,0,0,0,0,0,3,20,21,20,21,20,21,
20,20,20,21,20,21,20,21,20,0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,22,23,22,23,22,23,22,23,0,22,23,24,25,26,27,28,29,22,23,24,25,26,27,28,29,22,23,26,27,30,
31,24,25,22,23,26,27,30,31,32,33,0,22,23,24,25,30,31,26,27,22,23,24,25,26,27,28,29,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,34,35,36,3,37,38,39,0,0,0,0,
0,0,0,0,40,6,41,42,41,43,35,44,45,46,41,42,41,0,40,0,0,0,0,0,0,0,0,0,0,40,0,39,
0,3,0,37,0,40,0,39,0,3,0,37,0,0,35,0,47,0,48,0,39,0,35,0,47,0,48,0,49,0,40,0,
39,0,37,0,3,0,40,0,39,0,3,0,37,0,40,0,39,0,37,0,3,40,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,50,0,51,0,52,0,51,0,53,0,0,0,0,0,0,40,0,40,54,55,54,56,57,58,59,60,
54,55,54,56,61,40,0,0,0,0,0,0,0,0,0,35,0,48,0,47,0,48,0,35,0,6,0,47,0,48,0,35,
0,47,0,48,0,39,0,35,0,47,0,48,0,6,0,0,62,0,48,0,47,0,40,0,35,0,6,0,47,0,48,0,
62,0,48,0,47,0,40,35,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,63,61,63,61,63,61,0,61,54,55,54,56,57,58,59,60,54,55,54,56,40,0,0,0,4,5,4,5,4,5,
6,4,5,7,8,9,10,11,12,4,5,7,8,9,10,11,12,4,5,4,5,9,10,7,8,0,0,0,0,0,0,0,
0,0,4,13,14,15,16,17,18,19,4,13,14,15,9,10,11,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,64,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,64,0,64,0,64,0,64,0,64,0,64,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,61,0,61,0,61,0,0,40,41,42,41,43,35,44,45,46,41,42,41,43,0,0,0,0,0,0,
0,0,4,5,6,4,5,7,8,9,10,11,12,4,5,7,8,9,10,11,12,4,5,4,5,9,10,7,8,0,0,0,
0,0,0,0,0,0,4,13,14,15,16,17,18,19,4,13,14,15,9,10,11,12,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,65,35,36,3,37,38,39,0,0,0,0,0,0,0,0,61,61,
66,66,66,66,61,61,67,67,66,66,66,66,61,0,0,0,0,0,0,0,0,0,0,61,0,67,0,52,0,68,0,61,
0,67,0,52,0,68,0,61,0,52,0,66,0,67,0,0,0,0,0,0,0,0,0,69,61,0,67,0,66,0,52,0,
61,0,67,0,52,0,68,0,61,0,67,0,66,0,52,69,0,0,0,0,0,0,0,0,
};

/* machine_tree: verbatim from music.asm _machine_tree section */
static uint8_t machine_tree_data[] = {
8,0,0,0,48,0,0,0,0,8,0,0,0,20,0,0,0,0,128,63,0,0,128,63,0,0,0,0,0,0,0,65,
0,0,128,62,3,1,0,0,0,0,0,0,0,0,0,0,3,1,0,0,0,0,0,0,0,0,0,0,3,1,0,0,
0,0,0,0,0,0,0,0,2,0,0,160,69,0,0,208,62,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,80,61,2,0,0,0,0,128,6,0,0,5,0,0,0,48,0,0,0,0,64,0,0,0,0,128,63,0,0,
128,63,0,0,0,0,0,0,64,63,0,0,160,62,3,1,0,0,0,0,0,0,0,0,0,0,3,1,0,0,0,0,
0,0,0,0,0,0,3,1,0,0,0,0,0,0,0,0,0,0,2,0,0,176,70,0,0,128,63,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,4,0,0,32,63,0,0,192,63,6,0,0,0,
0,52,0,0,0,0,0,0,63,0,96,0,0,0,16,0,0,0,48,0,0,0,0,176,0,0,0,0,0,0,0,0,
128,63,0,0,0,0,0,0,80,62,0,0,64,64,1,2,0,0,0,0,208,62,0,0,192,63,3,2,0,0,0,0,
32,62,0,64,128,63,3,1,0,0,0,0,0,0,0,0,0,0,0,96,0,0,0,16,0,0,0,48,0,0,0,0,
176,0,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,0,63,0,0,0,63,1,2,0,0,0,0,208,62,0,
0,192,63,3,2,0,0,0,0,32,62,0,56,128,63,3,1,0,0,0,0,0,0,0,0,0,0,4,0,0,128,63,
0,0,128,63,5,0,0,0,64,0,0,0,63,2,0,0,128,70,0,0,80,63,0,0,192,54,0,0,160,69,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,0,0,224,63,0,0,128,63,1,0,0,0,0,28,122,0,0,
0,0,128,62,0,3,0,0,0,0,2,0,0,0,16,0,0,0,32,0,0,0,0,0,0,0,196,127,63,0,128,148,
58,0,0,0,63,0,0,128,63,1,2,0,0,0,0,80,62,0,0,128,63,3,1,0,0,0,0,0,0,0,0,0,
0,3,1,0,0,0,0,0,0,0,0,0,0,4,0,0,64,63,0,0,80,62,0,0,4,0,0,0,12,0,0,0,
16,0,0,0,14,0,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,128,62,0,0,32,63,3,2,0,0,0,
0,0,0,0,16,129,63,3,2,0,0,0,0,160,60,0,120,128,63,1,2,0,0,0,0,0,0,0,0,128,63,2,
0,0,64,70,0,0,160,62,0,0,128,55,0,0,248,68,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
1,0,0,0,0,14,61,0,0,0,0,208,62,4,0,0,0,63,0,0,0,63,0,0,64,1,0,0,40,0,0,0,
20,0,0,0,0,2,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,80,61,0,0,16,65,3,2,0,0,0,
0,0,0,0,0,129,63,3,2,0,0,0,0,32,62,0,128,128,63,3,3,0,0,0,0,0,0,0,0,240,59,0,
0,64,1,0,0,40,0,0,0,20,0,0,0,0,2,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,0,63,
0,0,208,61,3,2,0,0,0,0,0,0,0,96,128,63,3,2,0,0,0,0,192,62,0,56,128,63,3,3,0,0,
0,0,0,0,0,0,0,58,4,0,0,128,63,0,0,128,63,2,0,0,192,68,0,0,32,63,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,8,0,0,0,48,0,0,0,0,64,0,0,0,
128,0,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,208,61,0,0,192,64,3,2,0,0,0,0,0,0,0,
64,129,63,3,3,0,0,0,0,32,62,0,80,128,63,3,1,0,0,0,0,0,0,0,0,0,0,0,0,64,1,0,
48,0,0,0,0,128,0,0,0,0,3,0,0,0,128,63,0,0,128,63,0,0,0,0,0,0,32,63,0,0,36,60,
3,1,0,0,0,0,0,0,0,0,0,0,3,1,0,0,0,0,0,0,0,0,0,0,3,1,0,0,0,0,0,0,
0,0,0,0,2,0,0,208,69,0,0,160,62,0,0,56,55,0,0,32,69,0,0,192,55,0,0,32,69,0,0,0,
0,0,0,0,0,2,0,0,32,69,0,0,80,63,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,1,0,0,0,4,0,0,128,64,0,0,128,63,0,8,0,0,0,48,0,0,0,0,64,0,0,0,128,0,0,
0,0,0,0,0,0,128,63,0,0,0,0,0,0,32,63,0,0,32,62,3,2,0,0,0,0,0,0,0,32,129,63,
3,3,0,0,0,0,32,62,0,160,128,63,3,1,0,0,0,0,0,0,0,0,0,0,4,0,0,192,63,0,0,192,
63,0,8,0,0,0,48,0,0,0,0,26,0,0,0,128,2,0,0,0,0,0,0,0,128,63,0,0,0,0,0,0,
48,62,0,0,128,64,3,2,0,0,0,0,0,0,0,0,128,63,3,3,0,0,0,0,32,62,0,64,128,63,3,1,
0,0,0,0,0,0,0,0,0,0,2,0,0,160,67,0,0,80,63,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,1,0,0,0,4,0,0,128,63,0,0,64,63,4,0,0,128,63,0,0,192,63,2,0,0,
176,69,0,0,80,63,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,0,
0,0,0,68,8,0,0,0,0,32,63,6,0,0,0,0,9,13,0,0,0,0,112,63,6,0,0,0,0,218,16,0,
0,0,0,80,63,6,0,0,0,0,184,12,0,0,0,0,76,63,6,0,0,0,0,21,12,0,0,0,0,96,63,4,
0,0,208,62,0,0,32,64,3,0,0,128,63,0,0,0,0,0,0,0,0,255,
};

/* ── Machine: synth ─────────────────────────────────────────────────────── */
static void machine_synth(float **pedi, const uint8_t **pesi, int *pedx) {
    /* push one stack frame */
    *pedi += STACK_SAMPLES * 2;
    float *base = *pedi;
    memset(base, 0, STACK_FLOATS * sizeof(float));

    const uint8_t *instr = *pesi;
    const uint32_t *ui = (const uint32_t *)(const void *)instr;
    const float    *fi = (const float    *)(const void *)instr;

    uint32_t dur[4] = { ui[0], ui[1], ui[2], ui[3] };
    float noise_mix = fi[4];
    float freq_exp  = fi[5];
    float base_freq = fi[6];
    float volume    = fi[7];
    float stereo    = fi[8];
    const uint8_t *oscs = instr + 9 * 4;

    /* Hoist oscillator params — constant for the entire instrument */
    struct { uint8_t type, mode; float phshift, det, det2; } ocp[3];
    for (int oi = 0; oi < 3; oi++) {
        const uint8_t *op = oscs + oi * 12;
        ocp[oi].type  = op[0];
        ocp[oi].mode  = op[1];
        memcpy(&ocp[oi].phshift, op + 4, 4);
        memcpy(&ocp[oi].det,     op + 8, 4);
        ocp[oi].det2  = 2.0f - ocp[oi].det;
    }

    int edx = *pedx;

    for (int n = 0; n < NUM_ROWS * 16; n++, edx++) {
        int row  = edx >> 4;
        int step = edx & 15;
        uint8_t pat  = sequence_data[row];
        uint8_t note = pattern_data[(int)pat * 16 + step];

        note = (uint8_t)((unsigned)note * 2u); /* add al, al */
        if (note == 0) continue;

        const float *env = (note == 0xFE) ? ENV_STOP : ENV_NORMAL;

        /* note frequency via powf — replaces O(note) multiply loop */
        float freq = NOTE_FREQ_START * powf(NOTE_FREQ_STEP, (float)note) - base_freq;

        float phase   = 0.0f;
        float env_val = 0.0f;
        float *out = base + (size_t)n * MAX_NOTE_SAMPLES * 2;
        float *end = base + STACK_FLOATS;

        for (int seg = 0; seg < 4; seg++) {
            if (dur[seg] == 0) continue;
            float env_step = env[seg] / (float)dur[seg];
            for (uint32_t s = 0; s < dur[seg]; s++) {
                env_val += env_step;

                float new_freq = freq * freq_exp;
                freq = new_freq;
                phase += new_freq + base_freq;

                /* oscillators — params already in registers */
                float acc = 0.0f;
                for (int oi = 0; oi < 3; oi++) {
                    float o = osc_wave(phase * ocp[oi].det2, ocp[oi].phshift, ocp[oi].type)
                            + osc_wave(phase * ocp[oi].det,  ocp[oi].phshift, ocp[oi].type);
                    if      (ocp[oi].mode == 2) acc += o;
                    else if (ocp[oi].mode == 3) acc -= o;
                    else if (ocp[oi].mode == 4) acc *= o;
                }

                float samp = (acc + frandom() * noise_mix) * env_val * volume;
                if (out + 1 < end) {
                    out[0] = samp;
                    out[1] = samp * stereo;
                }
                out += 2;
            }
        }
    }

    *pesi += INSTRUMENT_SIZE;
    *pedx += NUM_ROWS * 16;
}

/* ── Machine: filter (state-variable filter + 2 LFOs) ──────────────────── */
/*
 * Params layout (32 bytes, 8 floats/ints):
 *   [0] cutoff   [1] resonance   [2] lfo1_freq   [3] cos_1 (MUTABLE LFO state)
 *   [4] lfo2_freq  [5] cos_2 (MUTABLE)  [6] dry  [7] filterType (int: 0=low,1=high,2=band)
 * Param-memory layout per call (32 bytes, 8 floats):
 *   [0] sin_1   [1] sin_2   [2] ch0_low [3] ch0_high [4] ch0_band
 *   [5] ch1_low [6] ch1_high [7] ch1_band
 */
static void machine_filter(float *edi, uint8_t *params, float *pm) {
    float *fp  = (float *)params;
    float *fpm = (float *)pm;

    /* Constant params */
    float cutoff = fp[0];
    float res    = fp[1];
    float lfo1f  = fp[2];
    float lfo2f  = fp[4];
    float dry    = fp[6];
    int   ftype  = ((int *)params)[7];

    /* Load all mutable state into locals so the compiler keeps them in regs */
    float s1 = fpm[0], s2 = fpm[1];
    float c1 = fp[3],  c2 = fp[5];
    float L0 = fpm[2], H0 = fpm[3], B0 = fpm[4];
    float L1 = fpm[5], H1 = fpm[6], B1 = fpm[7];

    for (int i = 0; i < TOTAL_SAMPLES; i++) {
        /* LFO1 quadrature step */
        float nc1 = c1 - s1 * lfo1f;  c1 = nc1;
        float ns1 = s1 + nc1 * lfo1f; s1 = ns1;
        /* LFO2 quadrature step */
        float nc2 = c2 - s2 * lfo2f;  c2 = nc2;
        float ns2 = s2 + nc2 * lfo2f; s2 = ns2;

        float f = (ns1 + ns2 + cutoff) * CUTOFF_SCALE;

        /* Channel 0 */
        float in0 = edi[i * 2];
        L0 += f * B0;
        float h0 = res * (in0 - B0) - L0;  H0 = h0;
        B0 = (f * h0 + B0) + 1e-30f - 1e-30f;  /* de-normalise */
        edi[i * 2]     = dry * in0 + (ftype == 0 ? L0 : ftype == 1 ? h0 : B0);

        /* Channel 1 */
        float in1 = edi[i * 2 + 1];
        L1 += f * B1;
        float h1 = res * (in1 - B1) - L1;  H1 = h1;
        B1 = (f * h1 + B1) + 1e-30f - 1e-30f;
        edi[i * 2 + 1] = dry * in1 + (ftype == 0 ? L1 : ftype == 1 ? h1 : B1);
    }

    /* Write mutable state back */
    fpm[0] = s1; fpm[1] = s2;
    fp[3]  = c1; fp[5]  = c2;
    fpm[2] = L0; fpm[3] = H0; fpm[4] = B0;
    fpm[5] = L1; fpm[6] = H1; fpm[7] = B1;
}

/* ── Machine: compressor ────────────────────────────────────────────────── */
static void machine_compressor(float *edi, const uint8_t *params) {
    const float *fp = (const float *)params;
    float thresh  = fp[0];
    float ratio   = fp[1];
    float postadd = fp[2];
    for (int i = 0; i < TOTAL_SAMPLES * 2; i++) {
        float x   = edi[i];
        float ax  = (x < 0.0f) ? -x : x;
        float sign = (x < 0.0f) ? -1.0f : 1.0f;
        float above = ax - thresh;
        float y;
        if (above <= 0.0f) {
            y = ax;
        } else {
            y = above * ratio + postadd + thresh;
        }
        edi[i] = y * sign;
    }
}

/* ── Machine: distortion_machine2: sin(x*a)*b ──────────────────────────── */
static void machine_distortion2(float *edi, const uint8_t *params) {
    const float *fp = (const float *)params;
    float a = fp[0], b = fp[1];
    int   n = TOTAL_SAMPLES * 2;
    /* Scale by a, then batch-vectorised sin via Accelerate, then scale by b */
    vDSP_vsmul(edi, 1, &a, edi, 1, (vDSP_Length)n);
    vvsinf(edi, edi, &n);
    vDSP_vsmul(edi, 1, &b, edi, 1, (vDSP_Length)n);
}

/* ── Machine: delay (ping-pong) ─────────────────────────────────────────── */
static void machine_delay(float *edi, uint8_t *params, float *delbuf) {
    int32_t *pos_p  = (int32_t *)params;
    int32_t  dlen   = ((int32_t *)params)[1];
    float    fb     = ((float *)params)[2];

    for (int i = 0; i < TOTAL_SAMPLES; i++) {
        (*pos_p)--;
        if (*pos_p < 0) *pos_p += dlen;
        int p = *pos_p;

        float wL = delbuf[p * 2];
        float wR = delbuf[p * 2 + 1];

        float oL = wL * fb + edi[i * 2];
        float oR = wR * fb + edi[i * 2 + 1];

        edi[i * 2]     = oL;
        edi[i * 2 + 1] = oR;

        /* ping-pong: swap channels in delay buffer */
        delbuf[p * 2]     = oR;
        delbuf[p * 2 + 1] = oL;
    }
}

/* ── Machine: allpass ───────────────────────────────────────────────────── */
static void machine_allpass(float *edi, uint8_t *params, float *delbuf) {
    int32_t *pos_p = (int32_t *)params;
    int32_t  dlen  = ((int32_t *)params)[1];
    float    fb    = ((float *)params)[2];

    for (int i = 0; i < TOTAL_SAMPLES; i++) {
        (*pos_p)--;
        if (*pos_p < 0) *pos_p += dlen;
        int p = *pos_p;

        float wL = delbuf[p * 2];
        float wR = delbuf[p * 2 + 1];

        float in_L = edi[i * 2];
        float in_R = edi[i * 2 + 1];

        /* cross-channel allpass (matches assembly) */
        float A = wL * fb + in_R;  /* A = wL*fb + inR */
        float B = wR * fb + in_L;  /* B = wR*fb + inL */

        float oL = wR - B * fb;    /* = wR*(1-fb²) - inL*fb */
        float oR = wL - A * fb;    /* = wL*(1-fb²) - inR*fb */

        edi[i * 2]     = oL;
        edi[i * 2 + 1] = oR;

        delbuf[p * 2]     = B;
        delbuf[p * 2 + 1] = A;
    }
}

/* ── Machine: mixer ─────────────────────────────────────────────────────── */
static void machine_mixer(float **pedi, const uint8_t *params) {
    const float *fp = (const float *)params;
    float vol_top  = fp[0];
    float vol_prev = fp[1];

    float *top  = *pedi;                    /* current stack top */
    float *prev = top - STACK_SAMPLES * 2;  /* one level down   */

    for (size_t i = 0; i < STACK_FLOATS; i++)
        prev[i] = top[i] * vol_top + prev[i] * vol_prev;

    *pedi -= STACK_SAMPLES * 2;   /* pop */
}

/* ── generateMusic ──────────────────────────────────────────────────────── */
void elevated_generate_music(float *output) {
    /* Allocate (MAX_STACK_HEIGHT+1) stack slots.
     * edi starts one slot BELOW output (slot 0 = pre-buffer).
     * output is at slot 1 (= &stack[STACK_FLOATS]).             */
    size_t total_floats = (size_t)(MAX_STACK_HEIGHT + 1) * STACK_FLOATS;
    float *stack = (float *)calloc(total_floats, sizeof(float));
    if (!stack) return;

    /* param_memory: zero-initialised, ~4.25 MB */
    size_t pm_bytes = 1114112 * 4 + 16;   /* TOTAL_PARAM_WORDS * 4 + alignment */
    uint8_t *param_mem_raw = (uint8_t *)calloc(pm_bytes, 1);
    if (!param_mem_raw) { free(stack); return; }
    /* 64-byte align (matches original BSS align=64) */
    uint8_t *pm = (uint8_t *)(((uintptr_t)param_mem_raw + 63) & ~(uintptr_t)63);

    /* mutable copy of machine_tree (machines modify their params in-place) */
    uint8_t *mt = (uint8_t *)malloc(sizeof(machine_tree_data));
    if (!mt) { free(param_mem_raw); free(stack); return; }
    memcpy(mt, machine_tree_data, sizeof(machine_tree_data));

    rng_seed = 0;

    float        *edi = stack;          /* starts at slot 0 */
    const uint8_t *esi = mt;
    uint8_t       *ebx = pm;
    int            edx = 0;
    int            eax = 0;            /* first machine = synth (0) */

    do {
        uint8_t *ebp = (uint8_t *)esi;

        switch (eax) {
        case 0: machine_synth(&edi, &esi, &edx);          break;
        case 1: machine_delay(edi, ebp, (float *)ebx);
                esi += 12; ebx += MAX_DELAY_SAMPLES * 8;  break;
        case 2: machine_filter(edi, ebp, (float *)ebx);
                esi += 32; ebx += 32;                      break;
        case 3: machine_compressor(edi, ebp);
                esi += 12;                                  break;
        case 4: machine_mixer(&edi, ebp);
                esi += 8;                                   break;
        case 5: machine_distortion2(edi, ebp);
                esi += 8;                                   break;
        case 6: machine_allpass(edi, ebp, (float *)ebx);
                esi += 12; ebx += MAX_DELAY_SAMPLES * 8;   break;
        default: break;
        }

        eax = (uint8_t)*esi++;
    } while (!(eax & 0x80));

    /* The final output is at stack slot 1 = &stack[STACK_FLOATS].
     * (edi should point there after all machines complete their mix.)
     * Copy to caller's output buffer.                                */
    float *result = stack + STACK_FLOATS;
    memcpy(output, result, STACK_FLOATS * sizeof(float));
    free(mt);
    free(param_mem_raw);
    free(stack);
}
