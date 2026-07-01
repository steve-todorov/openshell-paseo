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

# Playwright + headless Chromium and its OS dependencies (installs into
# /root/.cache/ms-playwright, correct for the root runtime user).
RUN npm install -g playwright@1.49.1 \
 && playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*

# bun, system-wide.
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s "bun-v1.1.38"

# nvm for root; pin its `default` alias to the base image's pre-installed Node so
# shells/projects get that version by default, while `nvm install <X>` still works.
ENV NVM_DIR=/root/.nvm
RUN mkdir -p "$NVM_DIR" \
 && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
 && . "$NVM_DIR/nvm.sh" \
 && BASE_NODE="$(node -v)" \
 && nvm install "$BASE_NODE" \
 && nvm alias default "$BASE_NODE"
