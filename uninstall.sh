#!/system/bin/sh
# ============================================================
# Android Nakedcore - 卸载脚本
# 停止服务并移除终端快捷方式；/data/adb/nakedcore 默认保留
# ============================================================

MODDIR=${0%/*}
NC_MODDIR="$MODDIR"
export NC_MODDIR
# shellcheck source=scripts/common.sh
. "$MODDIR/scripts/common.sh" 2>/dev/null

"$MODDIR/nakedcore" hotspot disable >/dev/null 2>&1
"$MODDIR/nakedcore" wifi stop >/dev/null 2>&1
"$MODDIR/nakedcore" core stop >/dev/null 2>&1
"$MODDIR/nakedcore" sub stop >/dev/null 2>&1

# 兜底清理：只匹配本模块的路径，避免误杀其它模块的进程
NC_SB_BIN="${NC_SB_BIN:-/data/adb/nakedcore/bin/sing-box}"
NC_MH_BIN="${NC_MH_BIN:-/data/adb/nakedcore/bin/mihomo}"
NC_SUB_BUNDLE="${NC_SUB_BUNDLE:-/data/adb/nakedcore/sub-store/sub-store.bundle.js}"
pkill -f "$NC_SB_BIN" 2>/dev/null
pkill -f "$NC_MH_BIN" 2>/dev/null
pkill -f "$NC_SUB_BUNDLE" 2>/dev/null
pkill -f "nakedcore wifi _daemon" 2>/dev/null
pkill -9 -f "nakedcore_daemon_loop" 2>/dev/null
rm -rf /data/adb/nakedcore/runtime 2>/dev/null
rm -f /data/adb/ksu/bin/nakedcore /data/adb/ap/bin/nakedcore /data/adb/magisk/nakedcore 2>/dev/null

echo "- 内核与 Sub-Store 已停止"
echo "- 快捷命令已移除"
echo "- 配置保留在 /data/adb/nakedcore（如需彻底删除请手动 rm -rf）"
