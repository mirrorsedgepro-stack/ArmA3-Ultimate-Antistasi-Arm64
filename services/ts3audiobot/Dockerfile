# TS3AudioBot: the Game Master's voice on TeamSpeak. It joins as a normal client and plays the
# WAVs openclaw-gm renders (mounted at /audio) when told to over its localhost web API.
# 0.12.0 is a self-contained .NET Core 3.1 build: it needs OpenSSL 1.1, hence Ubuntu 20.04.
# The arm64 build matches the DGX Spark host.
FROM ubuntu:20.04

ARG TS3AB_VERSION=0.12.0
ARG TS3AB_SHA256=052abb136b83e65f4140af0255f37f87873927e6f3e15f5a0a7cde34efbaeefb

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libopus0 libssl1.1 ffmpeg ca-certificates curl && \
    ln -sf /usr/lib/aarch64-linux-gnu/libopus.so.0 /usr/lib/aarch64-linux-gnu/libopus.so && \
    curl -fsSL -o /tmp/ab.tgz \
        "https://github.com/Splamy/TS3AudioBot/releases/download/${TS3AB_VERSION}/TS3AudioBot_linux_arm64.tar.gz" && \
    echo "${TS3AB_SHA256}  /tmp/ab.tgz" | sha256sum -c - && \
    mkdir /app && tar -xzf /tmp/ab.tgz -C /app && rm /tmp/ab.tgz && \
    apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# No ICU in the image; the bot doesn't need culture data.
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

COPY ts3audiobot.toml rights.toml bot.toml entrypoint.sh /template/
COPY plugins/ /template/plugins/
RUN chmod +x /template/entrypoint.sh

WORKDIR /data
ENTRYPOINT ["/template/entrypoint.sh"]
