#!/usr/bin/env bash
set -euaxo pipefail
docker build --build-arg ENABLED_MODULES="ndk lua" --build-arg APK_MIRROR="mirrors.tuna.tsinghua.edu.cn" -f Dockerfile-base -t docker.io/xinnj/file-server:$1 .