/*
 * synth.c  —  C port of the Elevated (rgba/tbc, 2009) synthesizer.
 *
 * Source: ~/Downloads/mtt_iq_Elevated/ (upstream source release by iq/Puryx/Mentor)
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
#include "music_tables_packed.h"

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

static __attribute__((always_inline)) float note_freq_scale(uint8_t note) {
    float scale = 1.0f;
    float step = NOTE_FREQ_STEP;
    while (note) {
        if (note & 1u) scale *= step;
        step *= step;
        note >>= 1;
    }
    return scale;
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
/* Music data  (packed from verbatim upstream tables in music_tables_raw.h)   */
/* ────────────────────────────────────────────────────────────────────────── */

static uint8_t pattern_data[PATTERN_DATA_LEN];
static uint8_t sequence_data[SEQUENCE_DATA_LEN];
static uint8_t machine_tree_data[MACHINE_TREE_DATA_LEN];
static float synth_stack[(size_t)(MAX_STACK_HEIGHT + 1) * STACK_FLOATS];
static uint8_t synth_param_mem[1114112 * 4] __attribute__((aligned(64)));
static uint8_t synth_machine_tree[MACHINE_TREE_DATA_LEN];
static uint8_t music_tables_ready = 0;

static __attribute__((noinline)) void zero_bytes(uint8_t *dst, size_t count) {
    volatile uint8_t *p = (volatile uint8_t *)dst;
    while (count--) *p++ = 0;
}

static __attribute__((noinline)) void zero_floats(float *dst, size_t count) {
    volatile float *p = (volatile float *)dst;
    while (count--) *p++ = 0.0f;
}

static void unpack_music_table(const uint8_t *src, uint8_t *dst, size_t len) {
    size_t out = 0;
    while (out < len) {
        uint8_t ctrl = *src++;
        size_t count = (size_t)(ctrl & 0x7F) + 1;
        if (ctrl & 0x80) {
            zero_bytes(dst + out, count);
        } else {
            memcpy(dst + out, src, count);
            src += count;
        }
        out += count;
    }
}

static void prepare_tables(void) {
    if (music_tables_ready) return;
    unpack_music_table(kPatternDataPacked, pattern_data, sizeof(pattern_data));
    unpack_music_table(kSequenceDataPacked, sequence_data, sizeof(sequence_data));
    unpack_music_table(kMachineTreeDataPacked, machine_tree_data, sizeof(machine_tree_data));
    music_tables_ready = 1;
}

/* ── Machine: synth ─────────────────────────────────────────────────────── */
static void machine_synth(float **pedi, const uint8_t **pesi, int *pedx) {
    /* push one stack frame */
    *pedi += STACK_SAMPLES * 2;
    float *base = *pedi;
    zero_floats(base, STACK_FLOATS);

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

        float freq = NOTE_FREQ_START * note_freq_scale(note) - base_freq;

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
    float scale = fp[0] * 0.31830988618f;
    float gain = fp[1];
    for (int i = 0; i < TOTAL_SAMPLES * 2; i++) {
        edi[i] = fast_sinpif(edi[i] * scale) * gain;
    }
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
    prepare_tables();

    /* Reuse large zero-fill scratch instead of importing heap helpers. */
    float *stack = synth_stack;
    uint8_t *pm = synth_param_mem;
    uint8_t *mt = synth_machine_tree;
    zero_floats(stack, (size_t)(MAX_STACK_HEIGHT + 1) * STACK_FLOATS);
    zero_bytes(pm, sizeof(synth_param_mem));
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
}

/* ── Instrument sync (visual light beams) ──────────────────────────────────
 * Exact port of DemoEffect() lines 184-200 from demo_deb.cpp.
 * Channel 2 of sequence_data drives the 8 visual beams via note&7.
 * q[5+i].x = d → exp(-d*0.0002): beam i brightness (0=bright,large=dim).
 */
void elevated_instrument_sync(int position, float *sync_out) {
    prepare_tables();

    int d = position;
    for (int i = 0; i < 8; i++) {
        sync_out[i] = (float)d;
    }
    int r = 0;
    do {
        int beat = r >> 4;
        if (beat >= NUM_ROWS) break;
        int pat_idx = (int)sequence_data[NUM_ROWS * 2 + beat];
        int note    = (int)pattern_data[(pat_idx << 4) | (r & 0xF)];
        if (note) {
            sync_out[note & 7] = (float)d;
        }
        r++;
        d -= MAX_NOTE_SAMPLES;
    } while (d >= 0);
}
