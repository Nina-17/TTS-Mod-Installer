#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VERSION='0.6.0'
BASE_PACKAGE=${1:-"${PROJECT_ROOT}/dist/TTSModInstaller-v0.5.4.zip"}
EXPECTED_BASE_HASH='23881499887918d7d607a1fa4a3af715eca48e9a118fad98b2de2c8d0972f1c2'

if [[ ! -f "${BASE_PACKAGE}" ]]; then
  print -u2 "未找到含官方 Windows 7-Zip 组件的基准包：${BASE_PACKAGE}"
  exit 2
fi

BASE_HASH=$(/usr/bin/shasum -a 256 "${BASE_PACKAGE}" | /usr/bin/awk '{print $1}')
if [[ "${BASE_HASH}" != "${EXPECTED_BASE_HASH}" ]]; then
  print -u2 "基准包 SHA-256 不匹配：${BASE_HASH}"
  exit 3
fi

if ! /usr/bin/grep -a -q "InstallerVersion = '${VERSION}'" "${PROJECT_ROOT}/TTSModInstaller.ps1"; then
  print -u2 "TTSModInstaller.ps1 版本号不是 ${VERSION}"
  exit 4
fi

WORK_ROOT=$(/usr/bin/mktemp -d "${PROJECT_ROOT}/.windows-package.XXXXXX")
trap '/bin/rm -rf "${WORK_ROOT}"' EXIT
PACKAGE_ROOT="${WORK_ROOT}/TTSModInstaller-v${VERSION}"
/bin/mkdir -p "${PACKAGE_ROOT}"

cd "${PACKAGE_ROOT}"
/usr/bin/unzip -q "${BASE_PACKAGE}" 'tools/*'

for FILE_NAME in \
  DESIGN.md \
  QUICK-START.txt \
  README.md \
  THIRD-PARTY-NOTICES.txt \
  TTSModInstaller.ps1 \
  TTSModUpdater.ps1 \
  '点我启动.cmd'; do
  /bin/cp "${PROJECT_ROOT}/${FILE_NAME}" "${PACKAGE_ROOT}/${FILE_NAME}"
done

OUTPUT_ZIP="${PROJECT_ROOT}/dist/TTSModInstaller-v${VERSION}.zip"
OUTPUT_HASH="${OUTPUT_ZIP}.sha256"
/bin/rm -f "${OUTPUT_ZIP}" "${OUTPUT_HASH}"
/usr/bin/find "${PACKAGE_ROOT}" -exec /usr/bin/touch -h -t 202601010000 {} +
cd "${PACKAGE_ROOT}"
/usr/bin/zip -X -q -r "${OUTPUT_ZIP}" .
HASH=$(/usr/bin/shasum -a 256 "${OUTPUT_ZIP}" | /usr/bin/awk '{print $1}')
print "${HASH}  ${OUTPUT_ZIP:t}" > "${OUTPUT_HASH}"

print "完成：${OUTPUT_ZIP}"
print "SHA-256：${HASH}"
