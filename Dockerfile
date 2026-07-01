# syntax=docker/dockerfile:1
# Custom OpenShell sandbox image — root-run toolbox extending the NVIDIA base.
# OpenShell starts sandbox containers as runAsUser:0, so everything installs for
# root; no custom user is created and the base image's user/passwd is left as-is.
ARG BASE_IMAGE=ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:aeef1c63f00e2913ea002ccb3aaf925f338b5c5d70e63576f0d95c16a138044e
FROM ${BASE_IMAGE}

# The base image may run as a non-root user; switch to root for all install steps.
# OpenShell starts sandboxes as runAsUser:0 at runtime.
USER root

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling needed by the installers below (curl/ca-certs are usually present;
# install defensively). unzip is required by the bun installer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

# Playwright + headless Chromium and its OS dependencies. Browsers go to a GLOBAL,
# world-readable path (/ms-playwright), NOT any user's home, so a single copy serves
# every sandbox and the unprivileged agent user (uid 998) can read it.
#
# Runtime resolution caveat: OpenShell STRIPS image ENV from the sandbox agent
# environment (verified: PLAYWRIGHT_BROWSERS_PATH is empty at runtime; HOME=/sandbox),
# and `sandbox exec` runs non-login shells (so profile.d/.bashrc aren't sourced). So we
# CANNOT rely on the env var at runtime. Instead we symlink the agent's default cache
# location (HOME/.cache/ms-playwright, i.e. /sandbox/.cache) to the global store; the
# agent's Playwright resolves browsers via that default path with zero env config. The
# symlink is just a pointer — the browsers themselves stay global. (/sandbox is the
# base image's agent home, virtiofs-shared into the sandbox, so the baked symlink
# survives at runtime.) The playwright npm package installs to /usr/lib/node_modules,
# also world-readable.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright@1.49.1 \
 && playwright install --with-deps chromium \
 && chmod -R a+rX /ms-playwright \
 && mkdir -p /sandbox/.cache \
 && ln -sfn /ms-playwright /sandbox/.cache/ms-playwright \
 && chmod -R a+rX /sandbox/.cache \
 && rm -rf /var/lib/apt/lists/*

# bun (pinned, BASELINE build). The kata sandbox guest CPU (Xeon X5650, Westmere)
# lacks AVX2, and the standard bun build SIGILLs on non-AVX2 CPUs; the baseline
# build targets SSE4.2. Installed directly (not via bun.sh/install, which picks the
# AVX2 build from the CI runner's CPU). `unzip` is installed in the apt step above.
RUN curl -fsSL -o /tmp/bun.zip \
      https://github.com/oven-sh/bun/releases/download/bun-v1.1.38/bun-linux-x64-baseline.zip \
 && unzip -q /tmp/bun.zip -d /tmp \
 && install -m 0755 /tmp/bun-linux-x64-baseline/bun /usr/local/bin/bun \
 && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
 && rm -rf /tmp/bun.zip /tmp/bun-linux-x64-baseline

# nvm for root; pin its `default` alias to the base image's pre-installed Node so
# shells/projects get that version by default, while `nvm install <X>` still works.
ENV NVM_DIR=/root/.nvm
RUN mkdir -p "$NVM_DIR" \
 && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
 && . "$NVM_DIR/nvm.sh" \
 && BASE_NODE="$(node -v)" \
 && nvm install "$BASE_NODE" \
 && nvm alias default "$BASE_NODE"
