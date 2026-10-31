#!/bin/bash
#
# 打开小组件视图预览（不把小组件放到桌面）。
#
# 直接编译 QuotaCore + Widget/QuotaWidget.swift + scripts/WidgetPreview/main.swift，
# 用共享容器里的真实快照 + 一条千问样例数据渲染小/中尺寸和带刷新按钮的实际中尺寸。
# 需要图形界面；第一次运行可能需要允许屏幕录制（截图时才需要）。
#
# 用法：
#   ./scripts/widget-preview.sh
#   PREVIEW_BUILD_DIR=/tmp/mqb-preview ./scripts/widget-preview.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD="${PREVIEW_BUILD_DIR:-$HOME/Library/Caches/ModelQuotaBar/widget-preview}"
rm -rf "$BUILD"
mkdir -p "$BUILD"

core_sources=()
while IFS= read -r file; do core_sources+=("$file"); done < <(find Sources/QuotaCore -name '*.swift' | sort)

echo "==> 编译小组件预览宿主"
swiftc \
  -Onone -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -o "$BUILD/WidgetPreview" \
  "${core_sources[@]}" \
  Widget/QuotaWidget.swift \
  scripts/WidgetPreview/main.swift

echo "==> 打开预览窗口（关闭窗口退出）"
exec "$BUILD/WidgetPreview"
