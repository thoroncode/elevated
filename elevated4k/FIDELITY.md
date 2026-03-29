# Elevated 4K Fidelity Contract

This directory exists to make a size-constrained build of Elevated, not to invent
a new look for it.

## Source Of Truth

The rendering intent should follow:

- the original Elevated effect and approved repository outputs
- iq's Function 2009 "behind elevated" seminar

That seminar is useful here because it states the actual engineering model behind
the intro instead of leaving contributors to guess from screenshots.

## Architectural Constraints

Treat these as part of the effect, not as optional style choices:

1. Elevated uses the "2 triangles plus 1,000,000" approach.
2. Primary intersections come from rasterized geometry and the z/intersection buffer.
3. Procedural texturing and lighting happen in fullscreen shading.
4. Postprocessing is a separate pass applied after shading.

For the 4K path, this means the safe default structure is:

1. Terrain/intersection pass.
2. Deferred shading pass into an intermediate scene color target.
3. Postprocessing pass from that shaded image to the drawable.

If you collapse or reorder these responsibilities, you are changing the effect and
must treat that as a visual experiment, not as a routine optimization.

## Visual Constraints

The following are not "just polish"; they are part of the intended image:

- terrain-driven camera behavior
- non-uniform fog / sky scattering feel
- lakes / water treatment
- the postprocess camera look
- brightness flicker, grain, vignette, and chromatic dispersion
- motion blur as a postprocess effect

In particular, motion blur is not permission to recompute or approximate the scene
with a different shading model during blur taps. If blur samples are taken from a
different image-producing path than the original, assume the result is wrong until
proven otherwise.

## Optimization Policy

Safe by default:

- whitespace/minification changes
- symbol shortening
- dead code removal
- host-side cleanup that does not alter rendering behavior
- build, packing, reporting, and workflow improvements

High risk and compare-required:

- shader math changes
- pass fusion or pass elimination
- reduced sample counts
- changed blur kernels or weighting
- altered camera equations
- changed terrain/noise functions
- changed color grading, fog, grain, vignette, or aberration behavior

## Validation Requirement

When a change can affect the image:

1. Capture or compare representative frames.
2. Check multiple timestamps, not only startup.
3. Keep the old path until the new one is proven acceptable.

If comparison tooling is missing, add it before claiming fidelity.

## Default Decision Rule

If a change saves bytes but changes the picture, it does not belong in the main
4K path without explicit approval.
