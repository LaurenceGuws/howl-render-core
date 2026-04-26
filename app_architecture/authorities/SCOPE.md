# Howl Render Core Scope Authority

Purpose: define what `howl-render-core` owns and what it does not own.

## In Scope

- backend-neutral render plan types
- frame-to-plan policy owned once for all backends
- text, atlas, damage, batching, and capability policy at renderer-core level
- deterministic tests for backend-neutral rendering behavior

## Out of Scope

- OpenGL, Vulkan, Metal, GLES, or software device/resource execution
- host window, input, or presentation ownership
- session or surface lifecycle ownership
- compatibility, fallback, or workaround paths
