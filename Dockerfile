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
 && apt-get install -y --no-install-recommends curl ca-certificates unzip zip python3-venv git \
 && rm -rf /var/lib/apt/lists/*

# Playwright + headless Chromium and its OS dependencies. Browsers go to a single
# GLOBAL, world-readable store — under /usr/local, NOT a custom top-level dir and NOT
# any user's home. This location matters: the OpenShell supervisor confines the
# unprivileged agent (uid 998) to an allowlist of standard system paths (/usr, /bin,
# /sandbox, /tmp). A custom root path like /ms-playwright is traversable but read/exec
# is DENIED for the agent (verified), whereas /usr/local is allowed (that's why bun
# works). So the browsers live at /usr/local/ms-playwright.
#
# Runtime resolution: OpenShell STRIPS image ENV from the agent environment (verified:
# PLAYWRIGHT_BROWSERS_PATH is empty at runtime; HOME=/sandbox) and `sandbox exec` runs
# non-login shells, so neither the env var nor profile.d is honored. We therefore
# symlink the agent's default cache path (HOME/.cache/ms-playwright, i.e. /sandbox/.cache)
# to the global store; Playwright's default resolution finds it with zero env config.
# The symlink is just a pointer — the browsers stay global. (/sandbox is the base
# image's agent home, virtiofs-shared into the sandbox, so the baked symlink survives.)
# The playwright npm package installs to /usr/lib/node_modules, also allowlisted.
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/ms-playwright
RUN npm install -g playwright@1.49.1 \
 && playwright install --with-deps chromium \
 && chmod -R a+rX /usr/local/ms-playwright \
 && mkdir -p /sandbox/.cache \
 && ln -sfn /usr/local/ms-playwright /sandbox/.cache/ms-playwright \
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

# --- Paseo (daemon + Desktop bundle) → /opt/Paseo ---
# getpaseo/paseo is PUBLIC; the CI build has open egress (the sandbox RUNTIME 403s on
# GitHub release redirects, which is exactly why Paseo is baked here, not fetched at runtime).
# The .deb pulls its Electron/GTK deps (libgtk-3, libnss3, ...) via apt.
RUN curl -fsSL -o /tmp/paseo.deb \
      https://github.com/getpaseo/paseo/releases/download/v0.1.102/Paseo-0.1.102-amd64.deb \
 && apt-get update \
 && apt-get install -y /tmp/paseo.deb \
 && rm -f /tmp/paseo.deb \
 && rm -rf /var/lib/apt/lists/*

# paseo CLI shim (allowlisted /usr/local/bin).
COPY scripts/paseo /usr/local/bin/paseo
RUN chmod 0755 /usr/local/bin/paseo

# --- coding agents Paseo orchestrates ---
# Installed via the vendors' OFFICIAL install scripts (npm publishing is deprecated for
# Claude Code), pinned to exact versions — we do not want moving builds in the image.
# Run as the RUNTIME agent (uid 998), NOT root: the scripts install into $HOME
# (~/.local/bin + ~/.local/share). As root that is /root/.local — unreadable by the
# agent and off its PATH (the same Landlock trap Playwright/nvm hit). Running as 998 with
# HOME=/sandbox lands the launchers AND their version/support dirs in the agent's real
# runtime home; /sandbox is read_write in the policy, and build-time HOME == runtime
# HOME == /sandbox, so each launcher resolves its ~/.local/share support dir at runtime.
# /sandbox is the base image's agent home; make it agent-owned so 998 can install into it.
# Recursive: pre-existing subdirs (e.g. /sandbox/.cache from the Playwright step, created
# as root) must also be writable — the Claude installer writes to $HOME/.cache/claude.
# jcodemunch-mcp — Python MCP server for code navigation. Installed GLOBALLY into a venv
# under /usr/local (allowlisted; /opt is NOT on uid 998's Landlock allowlist) with a stable
# /usr/local/bin/jcodemunch-mcp symlink that the MCP registration and every hook reference.
# Pinned hard: the runtime strips image ENV, so we bake the exact version (no runtime upgrade).
RUN python3 -m venv /usr/local/lib/jcodemunch \
 && /usr/local/lib/jcodemunch/bin/pip install --no-cache-dir jcodemunch-mcp==1.108.55 \
 && ln -sf /usr/local/lib/jcodemunch/bin/jcodemunch-mcp /usr/local/bin/jcodemunch-mcp \
 && chmod -R a+rX /usr/local/lib/jcodemunch \
 && /usr/local/bin/jcodemunch-mcp --version | grep -q '1.108.55'

RUN chown -R 998 /sandbox
USER 998
# Claude Code — native installer; first positional arg is the exact version to pin.
# Installs $HOME/.local/bin/claude (+ $HOME/.local/share/claude); downloads are temp.
RUN export HOME=/sandbox \
 && curl -fsSL https://claude.ai/install.sh | bash -s 2.1.185 \
 && rm -rf /sandbox/.claude/downloads
# GitHub Copilot CLI — PREFIX defaults to $HOME/.local for a non-root user, so the binary
# lands at /sandbox/.local/bin/copilot. VERSION pins the exact release tag.
RUN export HOME=/sandbox \
 && curl -fsSL https://gh.io/copilot-install | VERSION="v1.0.67" bash
# nvm — installed as the RUNTIME agent (uid 998) into /sandbox so it is agent-owned and on
# an allowlisted path (the old /root/.nvm was invisible to 998). The installer appends a
# self-contained snippet (it exports NVM_DIR inline) to $HOME/.bashrc, which an interactive
# runtime terminal sources even though image ENV is stripped and shells are non-login. Pin
# the `default` alias to the base image's Node so projects get it without a candidate baked.
RUN export HOME=/sandbox NVM_DIR=/sandbox/.nvm PROFILE=/sandbox/.bashrc \
 && mkdir -p "$NVM_DIR" \
 && touch "$PROFILE" \
 && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
 && . "$NVM_DIR/nvm.sh" \
 && BASE_NODE="$(node -v)" \
 && nvm install "$BASE_NODE" \
 && nvm alias default "$BASE_NODE" \
 && grep -q 'NVM_DIR' /sandbox/.bashrc
# SDKMAN — installed as uid 998 into /sandbox (agent-owned, allowlisted). Its installer
# appends a self-contained snippet (exports SDKMAN_DIR inline) to $HOME/.bashrc. No candidates
# are baked; the agent installs Java/Gradle/etc. on demand. Disable self-update in the config
# file because the ENV toggles do not survive the runtime image-ENV strip (same rule as
# claude/copilot). sdkman_auto_answer avoids interactive prompts during agent use.
RUN export HOME=/sandbox SDKMAN_DIR=/sandbox/.sdkman \
 && curl -fsSL "https://get.sdkman.io?rcupdate=true" | bash \
 && printf '%s\n' \
      'sdkman_auto_answer=true' \
      'sdkman_selfupdate_feature=false' \
      'sdkman_auto_selfupdate=false' \
      > /sandbox/.sdkman/etc/config \
 && grep -q 'SDKMAN_DIR' /sandbox/.bashrc
# Pre-install both marketplaces + the 5 enabled plugins as uid 998 so their caches are baked
# under /sandbox/.claude/plugins and resolve at runtime with no egress. A fresh claude HOME has
# NO marketplaces configured (not even claude-plugins-official), so BOTH must be added explicitly
# before install; the add clones the catalog into known_marketplaces.json. carlspring is excluded.
RUN export HOME=/sandbox \
 && claude plugin marketplace add anthropics/claude-plugins-official \
 && claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install superpowers@claude-plugins-official \
 && claude plugin install frontend-design@claude-plugins-official \
 && claude plugin install skill-creator@claude-plugins-official \
 && claude plugin install supabase@claude-plugins-official \
 && claude plugin install caveman@caveman \
 && for p in superpowers frontend-design skill-creator supabase caveman; do claude plugin list | grep -q "$p" || exit 1; done
# Register jcodemunch as a USER-scope MCP server (available in every project + git worktree)
# and install jcm's code-exploration policy as a USER-LEVEL RULE (~/.claude/rules/jcodemunch.md).
# Rules auto-load every session at the same priority as CLAUDE.md, so ~/.claude/CLAUDE.md stays
# generic (user-owned) and needs no @import. jcm can only print the policy (claude-md --generate
# → stdout), so we redirect it into the rules file ourselves. Both write under HOME=/sandbox,
# surviving the runtime ENV strip. The MCP command is the stable binary (no runtime uvx fetch).
RUN export HOME=/sandbox \
 && claude mcp add --scope user jcodemunch -- /usr/local/bin/jcodemunch-mcp \
 && claude mcp list | grep -q jcodemunch \
 && mkdir -p /sandbox/.claude/rules \
 && jcodemunch-mcp claude-md --generate --format full > /sandbox/.claude/rules/jcodemunch.md \
 && test -s /sandbox/.claude/rules/jcodemunch.md
# Pin versions HARD. OpenShell STRIPS image ENV at runtime, so env-var update switches
# won't apply — bake the disable into each tool's config file instead (both are read
# from $HOME=/sandbox at runtime, surviving the strip).
#   Claude:  the update-blocking env key lives in the COPYed docker/claude/settings.json
#            asset below (blocks ALL update paths: background check + `claude update`).
#   Copilot: autoUpdate:false is the config-file equivalent of COPILOT_AUTO_UPDATE=false.
RUN mkdir -p /sandbox/.claude /sandbox/.copilot \
 && printf '%s\n' '{ "autoUpdate": false }' > /sandbox/.copilot/settings.json
# Canonical claude settings — COPYed LAST so `claude plugin install` (above) cannot clobber
# enabledPlugins. Agent-owned so it is readable/writable at runtime under HOME=/sandbox.
COPY --chown=998:998 docker/claude/settings.json /sandbox/.claude/settings.json
USER root
# PATH bridge: the agent's PATH is /sandbox/.venv/bin:/usr/local/bin:/usr/bin:/bin, and
# ~/.local/bin is NOT on it. Symlink both launchers into /usr/local/bin (on PATH,
# allowlisted); each launcher still resolves its support dir under /sandbox/.local.
RUN ln -sf /sandbox/.local/bin/claude /usr/local/bin/claude \
 && ln -sf /sandbox/.local/bin/copilot /usr/local/bin/copilot
