# openshell-paseo

Custom [OpenShell](https://github.com/NVIDIA/OpenShell) sandbox image for the
carlspring cluster: the NVIDIA base + Playwright/headless Chromium + bun + nvm + SDKMAN,
run as root (OpenShell starts sandboxes as `runAsUser:0`).

Built and pushed to `ghcr.io/steve-todorov/openshell-paseo/sandbox` by GitHub
Actions on push to `main`. Consumed by `k8s-ai-carnival` via the OpenShell
HelmRelease `server.sandboxImage` pin (Flux rolls it).
