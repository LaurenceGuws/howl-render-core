# Howl Render Core Scope Authority

Purpose: define what `howl-render-core` owns and what it does not own.

## In Scope

- backend-neutral render plan types
- frame-to-plan policy owned once for all backends
- text, atlas, damage, batching, and capability policy at render-core level
- deterministic tests for backend-neutral rendering behavior

## Out of Scope

- OpenGL, Vulkan, Metal, GLES, or software device/resource execution
- host window, input, or presentation ownership
- session lifecycle ownership
- terminal-boundary lifecycle ownership beyond render-plan consumption
- compatibility, fallback, or workaround paths

