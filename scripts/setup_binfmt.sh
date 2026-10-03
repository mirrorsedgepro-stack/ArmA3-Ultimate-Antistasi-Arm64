#!/usr/bin/env bash
# ==============================================================================
# Multi-Architecture binfmt Emulation Setup
# Enables seamless execution of x86_64 Arma 3 Docker containers on ARM64 hosts
# ==============================================================================

set -euo pipefail

ARCH=$(uname -m)

echo "Detected host CPU architecture: ${ARCH}"

if [ "$ARCH" = "x86_64" ]; then
    echo "Host is already native x86_64. No binfmt emulation required."
    exit 0
fi

echo "Host is ${ARCH}. Checking if amd64 container execution is functional..."

if docker run --rm --platform linux/amd64 alpine uname -m >/dev/null 2>&1; then
    echo "Status: amd64 emulation is active and functional."
    exit 0
fi

echo "amd64 emulation is NOT active. Registering QEMU binfmt handlers..."
docker run --privileged --rm tonistiigi/binfmt --install all

echo "Verifying amd64 execution..."
TEST_ARCH=$(docker run --rm --platform linux/amd64 alpine uname -m)

if [ "$TEST_ARCH" = "x86_64" ]; then
    echo "Success: amd64 container support verified (returned: ${TEST_ARCH})."
else
    echo "Error: amd64 emulation test failed. Returned: ${TEST_ARCH}"
    exit 1
fi
