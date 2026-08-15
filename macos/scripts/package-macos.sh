#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MACOS_ROOT=${SCRIPT_DIR:h}
PROJECT_ROOT=${MACOS_ROOT:h}
VERSION='0.6.0'
ARCHIVE_PATH=${1:-}

if [[ -z "${ARCHIVE_PATH}" || ! -f "${ARCHIVE_PATH}" ]]; then
  print -u2 "用法：$0 <7z2602-mac.tar.xz>"
  exit 2
fi

EXPECTED_ARCHIVE_HASH='1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9'
EXPECTED_7ZZ_HASH='9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c'
EXPECTED_LICENSE_HASH='1790374e5352329cedb46ee3808930a88e9ca2f08b82b10fcf5cf605d2c301b1'
ARCHIVE_HASH=$(/usr/bin/shasum -a 256 "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')
if [[ "${ARCHIVE_HASH}" != "${EXPECTED_ARCHIVE_HASH}" ]]; then
  print -u2 "官方 7-Zip macOS 包 SHA-256 不匹配：${ARCHIVE_HASH}"
  exit 3
fi

WORK_ROOT=$(/usr/bin/mktemp -d "${MACOS_ROOT}/.build/package.XXXXXX")
trap '/bin/rm -rf "${WORK_ROOT}"' EXIT
SEVENZIP_ROOT="${WORK_ROOT}/sevenzip"
/bin/mkdir -p "${SEVENZIP_ROOT}"
/usr/bin/tar -xf "${ARCHIVE_PATH}" -C "${SEVENZIP_ROOT}"

for SPEC in "7zz:${EXPECTED_7ZZ_HASH}" "License.txt:${EXPECTED_LICENSE_HASH}"; do
  FILE_NAME=${SPEC%%:*}
  EXPECTED=${SPEC#*:}
  ACTUAL=$(/usr/bin/shasum -a 256 "${SEVENZIP_ROOT}/${FILE_NAME}" | /usr/bin/awk '{print $1}')
  if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
    print -u2 "${FILE_NAME} SHA-256 不匹配：${ACTUAL}"
    exit 4
  fi
done

"${SCRIPT_DIR}/test.sh" "${SEVENZIP_ROOT}/7zz"

cd "${MACOS_ROOT}"
export SWIFTPM_MODULECACHE_OVERRIDE="${MACOS_ROOT}/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${MACOS_ROOT}/.build/clang-cache"
/usr/bin/swift build --disable-sandbox -c release --arch arm64 --arch x86_64 --product TTSModInstallerApp
BIN_PATH=$(/usr/bin/swift build --disable-sandbox -c release --arch arm64 --arch x86_64 --product TTSModInstallerApp --show-bin-path)

PACKAGE_ROOT="${WORK_ROOT}/TTSModInstaller-macOS-v${VERSION}"
APP_ROOT="${PACKAGE_ROOT}/TTS Mod Installer.app"
/bin/mkdir -p "${APP_ROOT}/Contents/MacOS" "${APP_ROOT}/Contents/Resources/tools/7zip"
/bin/cp "${BIN_PATH}/TTSModInstallerApp" "${APP_ROOT}/Contents/MacOS/TTSModInstaller"
/bin/cp "${MACOS_ROOT}/Resources/Info.plist" "${APP_ROOT}/Contents/Info.plist"
/bin/cp "${SEVENZIP_ROOT}/7zz" "${APP_ROOT}/Contents/Resources/tools/7zip/7zz"
/bin/cp "${SEVENZIP_ROOT}/License.txt" "${APP_ROOT}/Contents/Resources/tools/7zip/License.txt"
/bin/chmod 755 "${APP_ROOT}/Contents/MacOS/TTSModInstaller" "${APP_ROOT}/Contents/Resources/tools/7zip/7zz"

/usr/bin/xcrun swift "${MACOS_ROOT}/Tools/GenerateIcon.swift" "${APP_ROOT}/Contents/Resources/AppIcon.icns"

/bin/cp "${MACOS_ROOT}/Distribution/macOS-快速开始.txt" "${PACKAGE_ROOT}/macOS-快速开始.txt"
/bin/cp "${MACOS_ROOT}/Distribution/首次打开说明.txt" "${PACKAGE_ROOT}/首次打开说明.txt"
/bin/cp "${PROJECT_ROOT}/THIRD-PARTY-NOTICES.txt" "${PACKAGE_ROOT}/THIRD-PARTY-NOTICES.txt"

/usr/bin/codesign --force --sign - --identifier io.github.nina-17.tts-mod-installer.7zz --timestamp=none "${APP_ROOT}/Contents/Resources/tools/7zip/7zz"
/usr/bin/codesign --force --deep --sign - --timestamp=none "${APP_ROOT}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_ROOT}"

/bin/mkdir -p "${PROJECT_ROOT}/dist"
OUTPUT_ZIP="${PROJECT_ROOT}/dist/TTSModInstaller-macOS-v${VERSION}.zip"
OUTPUT_HASH="${OUTPUT_ZIP}.sha256"
/bin/rm -f "${OUTPUT_ZIP}" "${OUTPUT_HASH}"
/usr/bin/find "${PACKAGE_ROOT}" -exec /usr/bin/touch -h -t 202601010000 {} +
cd "${WORK_ROOT}"
COPYFILE_DISABLE=1 /usr/bin/zip -X -q -r "${OUTPUT_ZIP}" "${PACKAGE_ROOT:t}"
HASH=$(/usr/bin/shasum -a 256 "${OUTPUT_ZIP}" | /usr/bin/awk '{print $1}')
print "${HASH}  ${OUTPUT_ZIP:t}" > "${OUTPUT_HASH}"

print "完成：${OUTPUT_ZIP}"
print "SHA-256：${HASH}"
