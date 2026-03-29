# Elevated 4K Reference Sources

This note records external references that are important for `elevated4k/`
optimization work, along with the concrete engineering constraints derived from
them.

The goal is to avoid "memory-driven" optimization, where a contributor vaguely
remembers the look and then ships a cheaper but different effect.

## External References

### 1. Function 2009 seminar

- Title: `behind elevated`
- Author: Inigo Quilez (`iq`)
- Event: Function 2009

Relevant takeaways captured from the seminar:

- Elevated uses the "2 triangles plus 1,000,000" approach.
- Primary ray intersections are solved by rasterized geometry plus a z/intersection
  buffer.
- Procedural texturing and lighting happen in fullscreen shading.
- Postprocessing is a separate third pass.
- Motion blur is part of the postprocess camera look.
- The camera look is intentionally hand-held and cinematic, not sterile CG.

### 2. WebGL reimplementation

- URL: `https://301.untergrund.net/elevated.html`
- Local snapshot: `doc/elevated.html`
- Snapshot size: `29241` bytes
- Snapshot SHA-256: `f5d76614ceedeb37338bbf49114cdbf2d2939e4c8de6230b8cc65854ab2109b5`

Relevant takeaways captured from the page source:

- The reimplementation uses a 3-pass structure:
  1. geometry / intersection pass
  2. deferred shading pass
  3. postprocess pass
- The postprocess blur samples the already shaded scene texture.
- The blur does not rerun full scene shading per blur tap.
- The shader structure, terrain/noise family, and post stack align with the
  historical presentation.
- The blur kernel is explicitly a 16-tap post blur with RGB channel offsets.
- The terrain/shading code keeps the same recognizable constants and formulas:
  `666`, `1024`, `vec2(512.,32.)`, `pow(c,.45)`, `c.xz*=0.98`, and
  `tex0(vec2(q[3].w*.1))` for grain.
- The timing/sync side also exposes the original-scale constants:
  total samples `9568256`, sync row scale `20840`, instrument step `5210`.

Cross-check against the current `elevated4k/` path:

- The current 4K renderer is aligned with the same 3-pass structure again.
- The current 4K post blur samples `sceneColor`, which matches this reference.
- If a future optimization removes `sceneColor` or reruns fullscreen shading inside
  blur taps, it is moving away from both the WebGL reference and the seminar model.

## Derived Constraints For Optimization Work

Treat the following as reference constraints unless the user explicitly approves
changing them:

1. Keep the conceptual 3-stage image pipeline intact:
   geometry/intersection, fullscreen shading, then postprocess.
2. Do not fuse passes if the result changes how the image is produced.
3. Do not change motion blur from "sample shaded image in post" into
   "recompute scene shading in blur taps."
4. Do not alter camera feel, fog/sky treatment, water/lake treatment, grain,
   flicker, vignette, or chromatic dispersion without comparison evidence.
5. Do not claim a byte-saving shader change is acceptable just because it still
   resembles Elevated at a glance.
6. Prefer exact recognizable formulas and constants when they appear in both the
   historical references and the checked-in implementation.

## Review Checklist

If an optimization changes shader math, pass structure, sampling, or post:

1. Compare output at representative timestamps.
2. Check more than startup.
3. Keep the previous path available until the new one is proven faithful.

If that comparison cannot be done yet, the change should stay experimental.
