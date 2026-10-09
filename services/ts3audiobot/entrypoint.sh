#!/bin/sh
# Seed /data on first start. The bot rewrites its own config (it stores its TeamSpeak identity
# in bots/overlord/bot.toml), so existing files are left alone: to change the bot's name or
# channel later, edit them in the ts3audiobot_data volume or remove the volume.
set -e
[ -f /data/ts3audiobot.toml ] || cp /template/ts3audiobot.toml /data/
[ -f /data/rights.toml ] || cp /template/rights.toml /data/
esc() { printf '%s' "$1" | sed 's/[\\"]/\\&/g; s/[&|]/\\&/g'; }
if [ ! -f /data/bots/overlord/bot.toml ]; then
    mkdir -p /data/bots/overlord
    sed -e "s|@NAME@|$(esc "${TS3AB_NAME:-[HQ] OVERLORD}")|" \
        -e "s|@ADDRESS@|$(esc "${TS3AB_ADDRESS:-127.0.0.1:9987}")|" \
        -e "s|@CHANNEL@|$(esc "${TS3AB_SPEAKER_CHANNEL:-TaskForceRadio/OVERLORD HQ}")|" \
        -e "s|@CHANNEL_PASSWORD@|$(esc "${TS3AB_CHANNEL_PASSWORD:-}")|" \
        /template/bot.toml > /data/bots/overlord/bot.toml
fi
# Second, silent bot that sits in the TFAR channel and only listens (plugins/OpenClawEars.cs). The
# speaking bot can't be in that channel: TFAR mutes every non-game client in a living player's channel.
if [ ! -f /data/bots/ears/bot.toml ]; then
    mkdir -p /data/bots/ears
    sed -e "s|@NAME@|$(esc "${TS3AB_EARS_NAME:-[HQ] OVERLORD (radio net)}")|" \
        -e "s|@ADDRESS@|$(esc "${TS3AB_ADDRESS:-127.0.0.1:9987}")|" \
        -e "s|@CHANNEL@|$(esc "${TS3AB_CHANNEL:-TaskForceRadio}")|" \
        -e "s|@CHANNEL_PASSWORD@|$(esc "${TS3AB_CHANNEL_PASSWORD:-}")|" \
        /template/bot.toml > /data/bots/ears/bot.toml
fi
# Plugins are ours, not user state: refresh them on every start.
mkdir -p /data/plugins
cp -f /template/plugins/*.cs /data/plugins/
exec /app/TS3AudioBot --non-interactive
