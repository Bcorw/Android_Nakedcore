#!/system/bin/sh
# ============================================================
# Android Nakedcore - 管理器 [执行] 按钮
# 音量+：启停当前内核；音量-：启停 Sub-Store
# 8 秒内无按键自动退出
# ============================================================

MODDIR=${0%/*}
NC_MODDIR="$MODDIR"
export NC_MODDIR

# shellcheck source=scripts/common.sh
. "$MODDIR/scripts/common.sh"
# shellcheck source=scripts/core.sh
. "$MODDIR/scripts/core.sh"
# shellcheck source=scripts/substore.sh
. "$MODDIR/scripts/substore.sh"

nc_init

GETEVENT=$(command -v getevent 2>/dev/null || echo /system/bin/getevent)
TIMEOUT_BIN=$(command -v timeout 2>/dev/null)

nc_sub_load_env
_core_state="已停止"
if nc_core_running "$NC_ACTIVE_CORE"; then
    _core_state="运行中 (PID: $(nc_core_pid "$NC_ACTIVE_CORE"))"
fi
_sub_state="已停止"
if nc_sub_running; then
    _sub_state="运行中 (PID: $(nc_sub_pid))"
fi

echo "=========================================="
echo "  Android Nakedcore"
echo "=========================================="
echo "  激活内核: $NC_ACTIVE_CORE  $_core_state"
echo "  Sub-Store: $_sub_state"
nc_sub_healthy && echo "  直达地址: $(nc_sub_direct_url)"
echo "------------------------------------------"
echo "  [音量+] 启停当前内核"
echo "  [音量-] 启停 Sub-Store"
echo "  8 秒内无按键退出"
echo "=========================================="

_line=""
if [ -n "$TIMEOUT_BIN" ]; then
    _line=$("$TIMEOUT_BIN" 8 "$GETEVENT" -qlc 1 2>/dev/null)
else
    _line=$("$GETEVENT" -qlc 1 2>/dev/null)
fi

case "$_line" in
    *KEY_VOLUMEUP*DOWN*)
        echo ""
        if nc_core_running "$NC_ACTIVE_CORE"; then
            "$NC_SELF" core stop "$NC_ACTIVE_CORE"
        else
            "$NC_SELF" core start "$NC_ACTIVE_CORE"
        fi
        ;;
    *KEY_VOLUMEDOWN*DOWN*)
        echo ""
        if nc_sub_running; then
            "$NC_SELF" sub stop
        else
            "$NC_SELF" sub start
        fi
        ;;
    *)
        echo ""
        echo "未检测到音量键，退出。"
        ;;
esac

sleep 2
exit 0
