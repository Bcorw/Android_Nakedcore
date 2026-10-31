#!/usr/bin/env bash
# ============================================================
# Android Nakedcore - 本地打包脚本
# 用法: ./build.sh [版本名]
# 输出: build/Android_Nakedcore-<版本>.zip
# 不需要网络，不内置大体积二进制
# ============================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="${OUT_DIR:-$ROOT/build}"
VERSION_ARG="${1:-}"

die() { echo "[Error] $1" >&2; exit 1; }
info() { echo "[*] $1"; }

# 打包工具：zip 优先，其次 python3（保留 Unix 权限位），最后 7z
ZIPPER=""
if command -v zip >/dev/null 2>&1; then
    ZIPPER="zip"
elif command -v python3 >/dev/null 2>&1; then
    ZIPPER="python3"
elif command -v 7z >/dev/null 2>&1; then
    ZIPPER="7z"
else
    die "未找到 zip / python3 / 7z，无法打包"
fi

[ -f "$ROOT/nakedcore" ] || die "缺少 nakedcore"
[ -f "$ROOT/scripts/common.sh" ] || die "缺少 scripts/common.sh"
[ -f "$ROOT/webroot/index.html" ] || die "缺少 webroot/index.html"
[ -f "$ROOT/META-INF/com/google/android/update-binary" ] || die "缺少 META-INF update-binary"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

info "复制模块文件到临时目录"
cp -a "$ROOT/module.prop" "$STAGE/"
cp -a "$ROOT/customize.sh" "$ROOT/service.sh" "$ROOT/action.sh" "$ROOT/uninstall.sh" "$STAGE/"
cp -a "$ROOT/nakedcore" "$STAGE/"
cp -a "$ROOT/scripts" "$STAGE/"
cp -a "$ROOT/webroot" "$STAGE/"
cp -a "$ROOT/META-INF" "$STAGE/"
cp -a "$ROOT/README.md" "$STAGE/" 2>/dev/null || true
cp -a "$ROOT/LICENSE" "$STAGE/" 2>/dev/null || true
cp -a "$ROOT/docs" "$STAGE/" 2>/dev/null || true

# 可选覆盖版本名
if [ -n "$VERSION_ARG" ]; then
    CODE=$(sed -n 's/^versionCode=//p' "$STAGE/module.prop" | head -n 1)
    [ -n "$CODE" ] || CODE=1
    sed -i "s/^version=.*/version=$VERSION_ARG/; s/^versionCode=.*/versionCode=$CODE/" "$STAGE/module.prop"
    info "版本覆盖为: $VERSION_ARG"
fi

VERSION=$(sed -n 's/^version=//p' "$STAGE/module.prop" | head -n 1)
[ -n "$VERSION" ] || die "module.prop 缺少 version"
SAFE_VERSION=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '_')

info "设置权限"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/nakedcore" "$STAGE"/*.sh "$STAGE"/scripts/*.sh "$STAGE/META-INF/com/google/android/update-binary"

info "校验 shell 语法"
for f in nakedcore scripts/common.sh scripts/core.sh scripts/substore.sh scripts/config.sh \
    scripts/task.sh scripts/status.sh scripts/ui.sh scripts/hotspot.sh scripts/connectivity.sh service.sh action.sh customize.sh uninstall.sh; do
    [ -f "$STAGE/$f" ] || die "缺少文件: $f"
    sh -n "$STAGE/$f" || die "语法错误: $f"
done

info "校验 WebUI"
for f in index.html app.js style.css favicon.svg; do
    [ -f "$STAGE/webroot/$f" ] || die "缺少 webroot/$f"
done
node --check "$STAGE/webroot/app.js" 2>/dev/null || info "未找到 node 或 app.js 语法检查跳过"

mkdir -p "$OUT_DIR"
OUT_ZIP="$OUT_DIR/Android_Nakedcore-${SAFE_VERSION}.zip"
rm -f "$OUT_ZIP"
case "$ZIPPER" in
    zip)
        (cd "$STAGE" && zip -rq "$OUT_ZIP" .)
        ;;
    python3)
        python3 - "$STAGE" "$OUT_ZIP" <<'PYZIP'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    os.remove(out)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(stage):
        dirs.sort(); files.sort()
        for name in dirs:
            rel = os.path.relpath(os.path.join(root, name), stage)
            info = zipfile.ZipInfo(rel + "/")
            info.external_attr = (0o40755 << 16) | 0x10
            z.writestr(info, b"")
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, stage)
            info = zipfile.ZipInfo(rel)
            info.external_attr = (os.stat(full).st_mode & 0o777) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())
PYZIP
        ;;
    7z)
        (cd "$STAGE" && 7z a -tzip -bd -y "$OUT_ZIP" . >/dev/null)
        ;;
esac

info "已生成: $OUT_ZIP"
info "大小: $(du -h "$OUT_ZIP" | cut -f1)"
info "内置版本:"
echo "  module:  $VERSION"
echo "  node:    首次使用时下载"
echo "  Sub-Store: 首次使用时下载"
echo "  sing-box/mihomo: 首次使用时下载"
