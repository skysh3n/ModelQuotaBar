#!/bin/bash
#
# 编译并运行单元测试。
#
# 不用 `swift test`：XCTest.framework 只随完整 Xcode 提供，只装 Command Line Tools
# 的机器上既没有它也没有 `xcrun xctest`。测试因此不依赖任何测试框架，
# 由 Tests/QuotaCoreTests/TestSupport.swift 里的执行器直接跑。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build/manual-tests"
ARCH="$(uname -m)"
MIN_MACOS="14.0"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

core_sources=()
while IFS= read -r file; do core_sources+=("$file"); done < <(find Sources/QuotaCore -name '*.swift' | sort)

test_sources=()
while IFS= read -r file; do test_sources+=("$file"); done < <(find Tests/QuotaCoreTests -name '*.swift' | sort)

echo "==> 编译被测模块 QuotaCore"
# -enable-testing 让测试可以访问 internal 的解析函数与网关工具。
swiftc \
  -Onone -wmo -parse-as-library -enable-testing \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -module-name QuotaCore \
  -emit-module -emit-module-path "$BUILD_DIR/QuotaCore.swiftmodule" \
  -emit-object -o "$BUILD_DIR/QuotaCore.o" \
  "${core_sources[@]}"

echo "==> 编译测试"
swiftc \
  -Onone -enable-testing \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -module-name QuotaCoreTests \
  -I "$BUILD_DIR" \
  -o "$BUILD_DIR/QuotaCoreTests" \
  "$BUILD_DIR/QuotaCore.o" \
  "${test_sources[@]}"

echo "==> 运行测试"
"$BUILD_DIR/QuotaCoreTests"