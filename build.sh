#!/usr/bin/env bash
set -euaxo pipefail
docker build --build-arg ENABLED_MODULES="ndk lua fancyindex" --build-arg APK_MIRROR="mirrors.tuna.tsinghua.edu.cn" -t docker.io/xinnj/file-server:$1 .