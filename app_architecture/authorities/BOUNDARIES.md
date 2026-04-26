# Howl Render Core Boundary Authority

## Hard Boundaries

- Expose backend-neutral/public render-core APIs only.
- Own planning policy, not backend execution.
- Import no platform, toolkit, or GPU-driver framework types.

## Forbidden Coupling

- No OpenGL, GLES, Vulkan, Metal, or software raster backend logic.
- No host, SDL, Android, Cocoa, or platform event coupling.
- No direct imports of sibling backend internals.
