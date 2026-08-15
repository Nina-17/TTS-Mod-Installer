#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MACOS_ROOT=${SCRIPT_DIR:h}
SEVENZIP_PATH=${1:-${TTS_MOD_INSTALLER_7ZZ:-}}

if [[ -z "${SEVENZIP_PATH}" || ! -x "${SEVENZIP_PATH}" ]]; then
  print -u2 "用法：$0 <官方 7zz 路径>"
  exit 2
fi

EXPECTED_HASH='9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c'
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "${SEVENZIP_PATH}" | /usr/bin/awk '{print $1}')
if [[ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]]; then
  print -u2 "7zz SHA-256 不匹配：${ACTUAL_HASH}"
  exit 3
fi

cd "${MACOS_ROOT}"
export SWIFTPM_MODULECACHE_OVERRIDE="${MACOS_ROOT}/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${MACOS_ROOT}/.build/clang-cache"
export TTS_MOD_INSTALLER_7ZZ="${SEVENZIP_PATH}"
/usr/bin/swift build --disable-sandbox
/usr/bin/swift run --disable-sandbox TTSModInstallerCoreTests
