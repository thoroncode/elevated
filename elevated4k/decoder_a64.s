// decoder_a64.s — Grammar A decoder, ARM64
//
// Grammar A token format:
//   0xxxxxxx   LITERAL run : count = x+1 (1–128), then count raw bytes
//   10lllooo   MATCH       : length = lll+3 (3–10), offset = (ooo<<8)|next (1–2047)
//   11llllll   RLE         : count = l+2  (2–65),  then 1 fill byte
//
// Entry convention (matches C ABI):
//   x0 = src        — pointer to first token byte (after 4-byte output_size header)
//   x1 = dst        — output buffer start
//   x2 = dst_end    — output buffer end (dst + output_size)
//
// All registers used: w3–w7 (scratch), x6 (match src pointer)
// Returns: nothing (void)
//
// Build for size measurement:
//   clang -target arm64-apple-macos13 -c decoder_a64.s -o decoder_a64.o
//   nm -j decoder_a64.o | head    (check symbol)
//   size decoder_a64.o            (check section sizes)
//   otool -tv decoder_a64.o       (disassemble to count instructions)
//
.section __TEXT,__text
.globl _decode_a
.align 2

_decode_a:
// ── outer loop ───────────────────────────────────────────────────────────────
_dec:
    cmp     x1, x2
    b.eq    _done
    ldrb    w3, [x0], #1           // load token byte
    tbnz    w3, #7, _not_lit       // bit7=1 → match or RLE

// ── LITERAL run: 0xxxxxxx ────────────────────────────────────────────────────
_lit:
    and     w4, w3, #0x7F
    add     w4, w4, #1             // count = (token & 0x7F) + 1
_lit_loop:
    ldrb    w5, [x0], #1
    strb    w5, [x1], #1
    subs    w4, w4, #1
    b.ne    _lit_loop
    b       _dec

// ── dispatch bit6 ────────────────────────────────────────────────────────────
_not_lit:
    tbnz    w3, #6, _rle           // bit6=1 → RLE

// ── MATCH: 10lllooo + 1 byte ─────────────────────────────────────────────────
_match:
    ubfx    w4, w3, #3, #3         // lll = bits[5:3]
    add     w4, w4, #3             // length = lll + 3
    and     w5, w3, #0x7           // ooo = bits[2:0]
    lsl     w5, w5, #8
    ldrb    w6, [x0], #1
    orr     w5, w5, w6             // offset = (ooo << 8) | next_byte
    sub     x6, x1, x5            // match_src = dst - offset
_match_loop:
    ldrb    w7, [x6], #1
    strb    w7, [x1], #1
    subs    w4, w4, #1
    b.ne    _match_loop
    b       _dec

// ── RLE: 11llllll + 1 byte ───────────────────────────────────────────────────
_rle:
    and     w4, w3, #0x3F
    add     w4, w4, #2             // count = (token & 0x3F) + 2
    ldrb    w5, [x0], #1           // fill byte
_rle_loop:
    strb    w5, [x1], #1
    subs    w4, w4, #1
    b.ne    _rle_loop
    b       _dec

_done:
    ret
