#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
MACOS_ROOT=${SCRIPT_DIR:h}
PROJECT_ROOT=${MACOS_ROOT:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${MACOS_ROOT}/Resources/Info.plist")
SPARKLE_ZIP=${1:-"${PROJECT_ROOT}/dist/TTSModInstaller-macOS-v${VERSION}.sparkle.zip"}
PREVIOUS_APPCAST=${2:-}
PUBLISH_TOOLS=${SPARKLE_PUBLISH_TOOLS:-"${MACOS_ROOT}/.build/artifacts/sparkle/Sparkle/bin"}
GENERATE_APPCAST="${PUBLISH_TOOLS}/generate_appcast"
SIGN_UPDATE="${PUBLISH_TOOLS}/sign_update"
KEY_ACCOUNT='io.github.nina-17.tts-mod-installer'

if [[ ! -f "${SPARKLE_ZIP}" ]]; then
  print -u2 "未找到 Sparkle 更新归档：${SPARKLE_ZIP}"
  exit 2
fi
if [[ ! -x "${GENERATE_APPCAST}" || ! -x "${SIGN_UPDATE}" ]]; then
  print -u2 "缺少 Sparkle 2.9.5 发布工具，请先执行 swift package resolve。"
  exit 3
fi

WORK_ROOT=$(/usr/bin/mktemp -d "${MACOS_ROOT}/.build/appcast.XXXXXX")
trap '/bin/rm -rf "${WORK_ROOT}"' EXIT
/bin/cp "${SPARKLE_ZIP}" "${WORK_ROOT}/${SPARKLE_ZIP:t}"
if [[ -n "${PREVIOUS_APPCAST}" && -f "${PREVIOUS_APPCAST}" ]]; then
  /bin/cp "${PREVIOUS_APPCAST}" "${WORK_ROOT}/appcast.xml"
fi

GENERATE_ARGUMENTS=(
  --download-url-prefix "https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v${VERSION}/"
  --link "https://github.com/Nina-17/TTS-Mod-Installer/releases/tag/v${VERSION}"
  --maximum-versions 3
  --maximum-deltas 0
)

if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  print -rn -- "${SPARKLE_ED25519_PRIVATE_KEY}" | "${GENERATE_APPCAST}" \
    --ed-key-file - "${GENERATE_ARGUMENTS[@]}" "${WORK_ROOT}"
  print -rn -- "${SPARKLE_ED25519_PRIVATE_KEY}" | "${SIGN_UPDATE}" \
    --verify --ed-key-file - "${WORK_ROOT}/appcast.xml"
else
  "${GENERATE_APPCAST}" --account "${KEY_ACCOUNT}" "${GENERATE_ARGUMENTS[@]}" "${WORK_ROOT}"
  "${SIGN_UPDATE}" --account "${KEY_ACCOUNT}" --verify "${WORK_ROOT}/appcast.xml"
fi

ARCHIVE_SIGNATURE=$(/usr/bin/xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
  "${WORK_ROOT}/appcast.xml")
if [[ -z "${ARCHIVE_SIGNATURE}" ]]; then
  print -u2 "appcast 中缺少更新归档 Ed25519 签名。"
  exit 4
fi
if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  print -rn -- "${SPARKLE_ED25519_PRIVATE_KEY}" | "${SIGN_UPDATE}" \
    --verify --ed-key-file - "${SPARKLE_ZIP}" "${ARCHIVE_SIGNATURE}"
else
  "${SIGN_UPDATE}" --account "${KEY_ACCOUNT}" --verify "${SPARKLE_ZIP}" "${ARCHIVE_SIGNATURE}"
fi

/bin/mkdir -p "${PROJECT_ROOT}/dist"
/bin/cp "${WORK_ROOT}/appcast.xml" "${PROJECT_ROOT}/dist/appcast.xml"
print "完成：${PROJECT_ROOT}/dist/appcast.xml"
