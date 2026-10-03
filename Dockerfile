# Patched Box64 for the Arma engine: upstream makecontext() truncates fiber
# arguments to 32 bits, which segfaults arma3server_x64 at mission init.
FROM debian:trixie AS box64-build
ARG BOX64_COMMIT=e5afb47da8b880e8cee73816ed51b0f811dc513b
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates cmake make gcc g++ python3 && \
    rm -rf /var/lib/apt/lists/*
COPY container_src/box64-makecontext-64bit.patch /tmp/
RUN git clone https://github.com/ptitSeb/box64.git /box64 && \
    cd /box64 && git checkout "$BOX64_COMMIT" && \
    git apply /tmp/box64-makecontext-64bit.patch && \
    cmake -B build -DARM64=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
    cmake --build build -j"$(nproc)" --target box64

FROM ghcr.io/sonroyaalmerol/steamcmd-arm64:latest

USER root

# SteamCMD keeps the base image's Box64; the Arma server and HCs use the patched one
COPY --from=box64-build /box64/build/box64 /usr/local/bin/box64-arma

# Install Python 3 and system utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        procps \
        curl \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure Box64 and SteamCMD environment
ENV STEAM_PLATFORM=linux64 \
    DEBUGGER=/usr/local/bin/box64 \
    ARMA_BOX64=/usr/local/bin/box64-arma \
    ARMA_BINARY=./arma3server_x64 \
    ARMA_CONFIG=main.cfg \
    ARMA_PARAMS="" \
    ARMA_PROFILE=main \
    ARMA_WORLD=empty \
    ARMA_LIMITFPS=60 \
    ARMA_CDLC="" \
    HEADLESS_CLIENTS=0 \
    HEADLESS_CLIENTS_PROFILE="\$profile-hc-\$i" \
    PORT=2302 \
    STEAM_BRANCH=public \
    STEAM_BRANCH_PASSWORD="" \
    STEAM_ADDITIONAL_DEPOT="" \
    MODS_LOCAL=true \
    MODS_PRESET="" \
    SKIP_INSTALL=false

# Create directories and wrapper script for steamcmd
RUN mkdir -p /arma3 /steamcmd && \
    printf '#!/usr/bin/env bash\nexport STEAM_PLATFORM=linux64\nexport DEBUGGER=/usr/local/bin/box64\nexec /home/steam/steamcmd/steamcmd.sh "$@"\n' > /steamcmd/steamcmd.sh && \
    chmod +x /steamcmd/steamcmd.sh && \
    ln -sf /steamcmd/steamcmd.sh /usr/local/bin/steamcmd

# Copy orchestration scripts
COPY container_src/launch.py /launch.py
COPY container_src/workshop.py /workshop.py
COPY container_src/local.py /local.py
COPY container_src/keys.py /keys.py

WORKDIR /arma3

CMD ["python3", "/launch.py"]
