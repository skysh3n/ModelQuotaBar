#!/bin/bash
#
# 构建 ModelQuotaBar.app（内含 QuotaWidget 小组件扩展）。
#
# 需要 Xcode。小组件扩展必须由 Apple 签发的证书签名才会被系统加载，
# 未签名 / ad-hoc 的扩展会被 pluginkit 静默忽略。
# 在 Xcode 里登录免费 Apple ID 并给两个 target 选好 Team 后即可构建。
#
# 用法：
#   TEAM_ID=ABCDE12345 ./scripts/build.sh   # 指定开发团队构建（推荐）
#   ./scripts/build.sh                      # 用工程里已配好的签名设置
#   NO_SIGN=1 ./scripts/build.sh            # 只验证能否编译，不做签名
#
# 注意：签名要读钥匙串里的私钥。屏幕锁定（钥匙串上锁）时 CodeSign 会失败，
# 先解锁屏幕再构建。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="ModelQuotaBar.xcodeproj"
SCHEME="ModelQuotaBar"
CONFIGURATION="${CONFIGURATION:-Release}"
# 构建目录刻意放在仓库外。仓库在 iCloud 同步的「桌面」里时，
# FileProvider 会给产物附加 com.apple.fileprovider.* / decmpfs 扩展属性，
# codesign 会直接拒绝（"resource fork, Finder information, or similar detritus not allowed"）。
DERIVED="${BUILD_DIR:-$HOME/Library/Caches/ModelQuotaBar/xcode}"
DIST="$ROOT/dist"
LOG="$DERIVED/xcodebuild.log"
# 产出用中文名：Finder 优先显示 CFBundleDisplayName，但系统缓存顽固时
# 文件名会先被看到，直接用中文名最省事。可执行文件名保持英文。
APP_BUNDLE_NAME="大模型额度.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild，请先安装 Xcode。" >&2
  exit 1
fi

mkdir -p "$DERIVED" "$DIST"

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

echo "==> xcodebuild $CONFIGURATION（完整日志：$LOG）"
# 完整输出落盘，终端只看关键行；用日志判断成败，避免管道吞掉退出码。
xcodebuild "${args[@]}" > "$LOG" 2>&1 || true
grep -E "error:|Signing Identity|BUILD (SUCCEEDED|FAILED)" "$LOG" | sort -u | head -20

if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo
  echo "构建失败，完整日志在 $LOG" >&2
  if grep -q "CodeSign" "$LOG" && grep -qiE "errSec|interaction|locked" "$LOG"; then
    echo "提示：CodeSign 失败常见原因是登录钥匙串被锁（屏幕锁定）。解锁后重试。" >&2
  fi
  exit 1
fi

BUILT="$DERIVED/Build/Products/$CONFIGURATION/ModelQuotaBar.app"
if [ ! -d "$BUILT" ]; then
  echo "构建失败：找不到 $BUILT" >&2
  exit 1
fi

echo "==> 复制到 dist/"
rm -rf "$DIST/ModelQuotaBar.app" "$DIST/$APP_BUNDLE_NAME"
# ditto 保留扩展属性与签名，普通 cp -R 可能破坏签名。
ditto "$BUILT" "$DIST/$APP_BUNDLE_NAME"
# dist/ 在仓库里，若仓库位于 iCloud 同步目录会被附加 FileProvider 属性，
# 安装到 /Applications 后可能影响签名校验，这里清掉。
xattr -cr "$DIST/$APP_BUNDLE_NAME" 2>/dev/null || true

if [ -n "${NO_SIGN:-}" ]; then
  echo
  echo "已构建（未签名）：$DIST/$APP_BUNDLE_NAME"
  echo "未签名的扩展不会被系统加载，小组件不会出现在组件库里。"
  exit 0
fi

echo
echo "构建完成：$DIST/$APP_BUNDLE_NAME"
echo "安装：cp -R \"$DIST/$APP_BUNDLE_NAME\" /Applications/"