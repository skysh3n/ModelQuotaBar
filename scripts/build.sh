#!/bin/bash
#
# 构建 ModelQuotaBar.app（内含 QuotaWidget 小组件扩展）。
#
# 需要 Xcode。小组件扩展必须由 macOS 认可的签名才能被系统加载，
# 因此这里默认走 Xcode 的签名流程：在 Xcode 里给两个 target 选好开发团队后，
# 用 ./scripts/build.sh 就能出一条能直接装到「应用程序」里的 .app。
#
# 用法：
#   ./scripts/build.sh                     # 用工程里已配好的签名设置
#   TEAM_ID=ABCDE12345 ./scripts/build.sh  # 临时指定开发团队
#   NO_SIGN=1 ./scripts/build.sh           # 只验证能否编译，不做签名
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="ModelQuotaBar.xcodeproj"
SCHEME="ModelQuotaBar"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED="$ROOT/.build/xcode"
DIST="$ROOT/dist"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "找不到 Xcode，请先安装 Xcode 并运行：sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED"
  build
)

if [ -n "${TEAM_ID:-}" ]; then
  args+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

if [ -n "${NO_SIGN:-}" ]; then
  args+=("CODE_SIGNING_ALLOWED=NO" "CODE_SIGNING_REQUIRED=NO")
fi

echo "==> xcodebuild $CONFIGURATION"
xcodebuild "${args[@]}" | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

BUILT="$DERIVED/Build/Products/$CONFIGURATION/ModelQuotaBar.app"
if [ ! -d "$BUILT" ]; then
  echo "构建失败：找不到 $BUILT" >&2
  exit 1
fi

echo "==> 复制到 dist/"
rm -rf "$DIST/ModelQuotaBar.app"
mkdir -p "$DIST"
# ditto 保留扩展属性与签名，普通 cp -R 可能破坏签名。
ditto "$BUILT" "$DIST/ModelQuotaBar.app"

if [ -n "${NO_SIGN:-}" ]; then
  echo
  echo "已构建（未签名）：$DIST/ModelQuotaBar.app"
  echo "未签名的扩展不会被系统加载，小组件不会出现在组件库里。"
  exit 0
fi

echo
echo "构建完成：$DIST/ModelQuotaBar.app"
echo "安装：cp -R \"$DIST/ModelQuotaBar.app\" /Applications/"