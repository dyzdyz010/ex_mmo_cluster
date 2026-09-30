# -----------------------------------------------------------------------------
# Voxim server — production image (release `voxim_server`)
#
# One BEAM node runs World / Scene / Auth / Gate; a multi-Scene topology
# (`VOXIM_TOPOLOGY`) starts extra Scene peer nodes from the same release.
# World data, certificates, catalogs and the topology file are mounted at
# runtime (see deploy/README.md); nothing world-specific is baked in.
#
# The server shares two sources with the Voxim client repository, supplied as a
# named build context:
#   docker build --build-context voxim=../Voxim -t voxim-server:<version> .
# (see deploy/build-image.sh).
#
# Target: linux/amd64.
# -----------------------------------------------------------------------------

# ============================================================================
# Stage 1 — Builder: Elixir + OTP + Rust + CMake (MsQuic for quicer)
# ============================================================================
FROM hexpm/elixir:1.18.5-erlang-27.2.4-debian-bookworm-20260824-slim AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      git \
      perl \
      pkg-config \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# Same toolchain as the verified local builds (rustler NIFs + the shared movement crate).
ARG RUST_VERSION=1.91.0
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /build/ex_mmo_cluster

# voxel_region reads the client's spatial constants at compile time and the
# movement NIF links the shared movement crate (its build.rs writes the C header
# into Plugins/VoximMovement/Source). Paths are relative to /build/ex_mmo_cluster.
COPY --from=voxim Source/Voxim/Voxel/VoxelSpatialConstants.h /build/Voxim/Source/Voxim/Voxel/VoxelSpatialConstants.h
COPY --from=voxim Plugins/VoximMovement/Native /build/Voxim/Plugins/VoximMovement/Native
COPY --from=voxim Plugins/VoximMovement/Source /build/Voxim/Plugins/VoximMovement/Source

COPY mix.exs mix.lock ./
COPY config config
COPY apps apps
COPY rel rel

RUN mix deps.get --only prod \
 && mix deps.compile \
 && mix compile \
 && mix release voxim_server

# ============================================================================
# Stage 2 — Runtime
# ============================================================================
# Same Debian bookworm base as the builder (keeps OpenSSL / libstdc++ ABI identical to the build).
FROM hexpm/elixir:1.18.5-erlang-27.2.4-debian-bookworm-20260824-slim AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libstdc++6 \
      libncurses6 \
      openssl \
      libssl3 \
      ca-certificates \
      tini \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1000 voxim \
 && useradd --system --uid 1000 --gid voxim --home /app --shell /bin/sh voxim \
 && install -d -o voxim -g voxim /app

# The release writes its tmp dir under /app at start: the directory itself must belong to voxim
# (COPY --chown only changes the copied files).
WORKDIR /app
COPY --from=builder --chown=voxim:voxim /build/ex_mmo_cluster/_build/prod/rel/voxim_server ./
USER voxim

# Distribution is required: Scene peer nodes connect back to this node. Secrets
# (SECRET_KEY_BASE, MMO_DB_PASSWORD, RELEASE_COOKIE) and the world/cert paths are
# injected by the deployment (deploy/.env).
ENV PHX_SERVER=true \
    RELEASE_DISTRIBUTION=name \
    RELEASE_NODE=voxim@127.0.0.1 \
    AUTH_PORT=24640 \
    VOXIM_QUIC_PORT=24643

EXPOSE 24640 24643/udp

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
