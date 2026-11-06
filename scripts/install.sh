#!/bin/bash
#
# 构建并安装到 /Applications，然后启动，方便直接测试。
#
# 复用 build.sh 的构建流程（默认 Release），安装时先退出正在运行的实例，
# 再整体替换 /Applications 下的应用，避免测试到旧版本。
#
# 用法：
#   ./scripts/install.sh                # Release 构建 + 安装 + 启动
#   CONFIGURATION=Debug ./scripts/install.sh
#   TEAM_ID=ABCDE12345 ./scripts/install.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE_NAME="大模型额度.app"
DEST="/Applications/$APP_BUNDLE_NAME"

# 先构建，dist/ 里的产物由 build.sh 负责生成与清理扩展属性
"$ROOT/scripts/build.sh"

if [ ! -d "$ROOT/dist/$APP_BUNDLE_NAME" ]; then
  echo "构建产物不存在：$ROOT/dist/$APP_BUNDLE_NAME" >&2
  exit 1
fi

echo "==> 退出正在运行的实例"
pkill -x ModelQuotaBar 2>/dev/null || true
# 小组件扩展进程会跨重装常驻，不杀掉的话系统继续用内存里的旧代码：
# 新加的来源不会出现在小组件配置列表里。系统会在下次渲染时重新拉起。
pkill -x QuotaWidget 2>/dev/null || true
sleep 1

echo "==> 安装到 $DEST"
rm -rf "$DEST"
# ditto 保留签名与扩展属性；dist 在 iCloud 目录时属性会被重新附加，复制后再清一次
ditto "$ROOT/dist/$APP_BUNDLE_NAME" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

open "$DEST"
echo "已安装并启动：$DEST"
