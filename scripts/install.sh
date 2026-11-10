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

# 刷新 LaunchServices 注册记录，解决 WidgetKit 扩展 bundleStubNotSupported 错误。
# 根因：LaunchServices DB 里同一个 bundle id 有多条 path 记录（/Applications 正式版、
# 仓库 dist 构建产物、已删除目录的历史记录），导致扩展产物 bundle stub 与 DB 对不上，
# chronod 日志报 WidgetKit.WidgetArchiver.ValidationError.bundleStubNotSupported，
# 时间线写不进缓存，小组件永远显示灰色占位骨架。
# 解决：注销非 /Applications 的记录 + 强制注册目标路径。
echo "==> 刷新 LaunchServices 注册"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  # 注销仓库 dist 里的构建产物记录
  DIST_PATH="$ROOT/dist/$APP_BUNDLE_NAME"
  if [ -d "$DIST_PATH" ]; then
    echo "  注销 dist 产物：$DIST_PATH"
    "$LSREGISTER" -u "$DIST_PATH" 2>/dev/null || true
  fi

  # 从 dump 里找出同 bundle 但不等于安装目标的 path，逐条注销（含已不存在的历史记录）
  echo "  清理同 bundle 的多余注册记录..."
  while IFS= read -r line; do
    # 提取 path: 后面的路径（去掉末尾的 inode 号如 " (0x6850)"）
    if [[ "$line" =~ path:\ *([^[:space:]].+?)[[:space:]]*\(0x[0-9a-f]+\)*[[:space:]]*$ ]]; then
      reg_path="${BASH_REMATCH[1]}"
      # 去掉首尾空白
      reg_path="$(echo "$reg_path" | xargs)"
      # 跳过安装目标本身
      if [ "$reg_path" != "$DEST" ]; then
        echo "  注销多余记录：$reg_path"
        "$LSREGISTER" -u "$reg_path" 2>/dev/null || true
      fi
    fi
  done < <("$LSREGISTER" -dump 2>/dev/null | grep -A2 "$APP_BUNDLE_NAME" | grep "path:" || true)

  # 强制注册 /Applications 下的目标
  echo "  强制注册：$DEST"
  "$LSREGISTER" -f "$DEST" 2>/dev/null || true
else
  echo "  警告：lsregister 不存在，跳过 LaunchServices 刷新"
fi

open "$DEST"
echo "已安装并启动：$DEST"
echo ""
echo "提示：如果小组件仍显示灰色占位骨架，请手动移除小组件后重新添加。"
