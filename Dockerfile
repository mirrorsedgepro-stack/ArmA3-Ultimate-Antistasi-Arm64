# x86_64 userland that FEX-Emu runs launch.py, SteamCMD, the server and the
# HCs in. Building this stage on an ARM64 host needs amd64 binfmt emulation
# (scripts/setup_binfmt.sh registers QEMU for it).
FROM --platform=linux/amd64 debian:trixie-slim AS x86-rootfs
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        procps \
        curl \
        ca-certificates \
        libgcc-s1 \
        libc6:i386 \
        lib32gcc-s1 \
        lib32stdc++6 && \
    rm -rf /var/lib/apt/lists/*
RUN mkdir -p /steamcmd && \
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /steamcmd

# ARM64 host side: FEX-Emu emulates the whole x86 userland (real x86 glibc),
# unlike Box64, whose partial makecontext/swapcontext emulation deadlocks
# Arma's script fibers when Antistasi starts a new campaign.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common gpg-agent && \
    add-apt-repository -y ppa:fex-emu/fex && \
    apt-get update && \
    apt-get install -y --no-install-recommends fex-emu-armv8.4 && \
    apt-get purge -y software-properties-common gpg-agent && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/machine-id /var/lib/dbus/machine-id

# FEX resolves guest paths in the RootFS first and falls back to the host, so
# drop everything that must come from the container or its volumes instead
COPY --from=x86-rootfs / /opt/x86-rootfs
RUN mv /opt/x86-rootfs/steamcmd /steamcmd && \
    rm -rf /opt/x86-rootfs/etc/resolv.conf /opt/x86-rootfs/etc/hosts /opt/x86-rootfs/etc/hostname \
           /opt/x86-rootfs/root /opt/x86-rootfs/tmp /opt/x86-rootfs/home && \
    mkdir -p /arma3

ENV FEX_ROOTFS=/opt/x86-rootfs \
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

# Copy orchestration scripts
COPY container_src/launch.py /launch.py
COPY container_src/workshop.py /workshop.py
COPY container_src/local.py /local.py
COPY container_src/keys.py /keys.py

WORKDIR /arma3

# Everything below launch.py (SteamCMD, server, HCs) inherits FEX via execve
CMD ["FEX", "/usr/bin/python3", "/launch.py"]
