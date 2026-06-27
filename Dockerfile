# Docker image: run all evm-hack-registry POCs fully offline via anvil.
#
# Builds a self-contained image with Foundry (forge + anvil) and the registry. At
# runtime each POC is run by _shared/run_poc.sh, which spins up its own anvil loaded
# with the POC's committed anvil_state.json — no network needed.
#
# Build:  docker build -t evm-hack-registry .
# Run:    docker run --rm evm-hack-registry                            # run all, parallel
#         docker run --rm evm-hack-registry 2026-06-ATM_LP_Burn_exp    # run one POC
#         docker run --rm --network none evm-hack-registry 2018-04-BEC_exp   # offline
#         docker run --rm evm-hack-registry -vvvvv 2026-06-ATM_LP_Burn_exp    # verbose
#
# The first arg naming an existing POC folder runs that single POC (remaining args go
# to forge); otherwise all POCs run in parallel.

FROM ghcr.io/foundry-rs/foundry:v1.5.0 AS foundry

FROM debian:bookworm-slim

# foundry binaries from the official image
COPY --from=foundry /usr/local/bin/forge /usr/local/bin/forge
COPY --from=foundry /usr/local/bin/anvil /usr/local/bin/anvil
COPY --from=foundry /usr/local/bin/cast  /usr/local/bin/cast

# runtime deps used by the harness: bash, nc, procps (nproc/sysctl), coreutils
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash netcat-openbsd procps ca-certificates coreutils sed gawk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /registry
COPY . /registry/

# foundry home + solc compiler cache live here; pre-create so runtime needs no setup.
ENV FOUNDRY_DIR=/root/.foundry
RUN mkdir -p /root/.foundry

# Pre-install every solc version the POCs require, at BUILD time (network available).
# Runtime is fully offline, so these must be baked in. Compiling a few representative
# POCs spanning the solidity range (0.4.x .. 0.8.x) auto-installs each needed solc into
# /root/.foundry via svm; those binaries ship in the image.
RUN cd /registry && \
    for p in 2018-04-BEC_exp 2020-04-LendfMe_exp 2021-05-PancakeBunny_exp \
             2023-03-Euler_exp 2024-02-DN404_exp 2026-06-ATM_LP_Burn_exp ; do \
      ( cd "$p" && forge build --force >/dev/null 2>&1 || true ) ; \
    done && \
    rm -rf /registry/*/out /registry/*/cache

ENTRYPOINT ["/registry/_shared/docker_entrypoint.sh"]
