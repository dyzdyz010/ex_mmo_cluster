# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Hemifuture MMO server — production image
#
# Single-container MVP: all maintained umbrella apps packed into one Elixir
# release (hemi_server). Rust NIFs (scene_ops / octree / coordinate_system /
# movement_engine) are compiled inside the builder stage via Rustler.
#
# Target: linux/amd64 only.
# -----------------------------------------------------------------------------

# ============================================================================
# Stage 1 — Builder: Elixir + OTP + Node + Rust toolchain
# ============================================================================
FROM hexpm/elixir:1.18.4-erlang-28.3.1-debian-bookworm-20250908-slim AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# System build deps + Node (for Phoenix asset pipeline) + curl (for rustup).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      pkg-config \
      libssl-dev \
      nodejs \
      npm \
 && rm -rf /var/lib/apt/lists/*

# Rust toolchain — pinned to 1.94 stable. rapier3d-f64 + rustler 0.37 verified.
ARG RUST_VERSION=1.94.0
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Hex + rebar (release deps fetch).
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy the full source tree. .dockerignore excludes _build, deps, docs, .omc,
# apps/*/target, node_modules, etc. For umbrella releases the per-app mix.exs
# files are all required before `mix deps.get`, so a partial-copy cache trick
# would be brittle — accept slower cache invalidation for simplicity.
COPY mix.exs mix.lock ./
COPY config config
COPY apps apps

# Fetch + compile deps. `--only prod` trims dev/test dependencies.
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile the umbrella (triggers Rustler → Cargo compile for all 4 NIFs).
RUN mix compile

# Phoenix asset pipeline: tailwind --minify, esbuild --minify, phx.digest.
# Root alias `assets.deploy` fans out into both Phoenix apps (see mix.exs).
RUN mix assets.deploy

# Build the release. Output: _build/prod/rel/hemi_server/
RUN mix release hemi_server

# ============================================================================
# Stage 2 — Runtime: minimal debian-slim + libssl + ncurses (ERTS dep)
# ============================================================================
FROM debian:bookworm-slim AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# ERTS is bundled via include_erts:true, but it still requires these shared
# libraries at the OS level.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libstdc++6 \
      libncurses6 \
      openssl \
      libssl3 \
      ca-certificates \
      tini \
 && rm -rf /var/lib/apt/lists/*

# Non-root user.
RUN groupadd --system --gid 1000 hemi \
 && useradd --system --uid 1000 --gid hemi --home /app --shell /bin/bash hemi

WORKDIR /app

COPY --from=builder --chown=hemi:hemi /app/_build/prod/rel/hemi_server ./

USER hemi

# Defaults that can be overridden by docker-compose env_file / environment.
# Actual secrets (SECRET_KEY_BASE, DB creds, RELEASE_COOKIE) must be injected.
ENV PHX_SERVER=true \
    DISABLE_CLUSTER=true \
    RELEASE_DISTRIBUTION=none \
    AUTH_PORT=4000 \
    VISUALIZE_PORT=4001 \
    GATE_TCP_PORT=29000

EXPOSE 4000 4001 29000

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/hemi_server"]
CMD ["start"]
