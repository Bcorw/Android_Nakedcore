#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 公共函数库
# 被 nakedcore / service.sh / action.sh / task.sh 引用
# 运行环境: Android busybox ash（不要使用 bash 数组等特性）
# ============================================================

# ---------- 路径 ----------
NC_MODDIR="${NC_MODDIR:-/data/adb/modules/Android_Nakedcore}"
NC_SELF="$NC_MODDIR/nakedcore"
NC_SCRIPT_DIR="$NC_MODDIR/scripts"
NC_DATA="${NC_DATA:-/data/adb/nakedcore}"
NC_BIN="$NC_DATA/bin"
NC_SB="$NC_DATA/sing-box"
NC_MH="$NC_DATA/mihomo"
NC_SUB="$NC_DATA/sub-store"
NC_SUB_DATA="$NC_SUB/data"
NC_SUB_FE="$NC_SUB/frontend"
NC_SUB_ENV="$NC_SUB/sub_store.env"
NC_RUN="$NC_DATA/run"
NC_TASKS="$NC_RUN/tasks"
NC_TMP="$NC_RUN/tmp"
NC_BACKUP="$NC_DATA/backup"
NC_SETTINGS="$NC_DATA/settings.conf"
NC_MODULE_PROP="$NC_MODDIR/module.prop"
NC_LOG_BOOT="$NC_RUN/boot.log"
NC_UPDATE_ENV="$NC_RUN/update_check.env"
NC_WIFI_DIR="$NC_DATA/wifi"
NC_WIFI_SSIDS="$NC_WIFI_DIR/ssids"
NC_WIFI_STATE="$NC_WIFI_DIR/suspended"
NC_WIFI_MANUAL="$NC_WIFI_DIR/manual_stop"
NC_WIFI_LAST="$NC_WIFI_DIR/last"
NC_WIFI_LOG="$NC_RUN/wifi.log"
NC_WIFI_PID="$NC_RUN/wifi.pid"
NC_WIFI_INTERVAL=5
NC_HOTSPOT_LOG="$NC_RUN/hotspot.log"
NC_HOTSPOT_STATE="$NC_RUN/hotspot.state"
NC_HOTSPOT_LOCAL_TABLE=1888
NC_HOTSPOT_RULE_PREF=9000
NC_HOTSPOT_IIF_PREF=9010

# 常用文件
NC_SB_BIN="$NC_BIN/sing-box"
NC_MH_BIN="$NC_BIN/mihomo"
NC_NODE_BIN="$NC_BIN/node"
NC_SB_CONFIG="$NC_SB/config.json"
NC_MH_CONFIG="$NC_MH/config.yaml"
NC_SUB_BUNDLE="$NC_SUB/sub-store.bundle.js"

# 默认设置
NC_DEF_ACTIVE_CORE="sing-box"
NC_DEF_AUTO_START="false"
NC_DEF_SUB_AUTO_START="false"
NC_DEF_GH_PROXY="https://gh-proxy.com"
NC_DEF_SB_CHANNEL="stable"
NC_DEF_MH_CHANNEL="stable"
NC_DEF_WIFI_GUARD="false"
NC_DEF_HOTSPOT_ENABLED="false"
NC_DEF_HOTSPOT_USB="true"

# ---------- 环境 ----------
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:$PATH"
export TZ="${TZ:-Asia/Shanghai}"

# 定位 BusyBox（KSU/APatch/Magisk 自带，功能最全）
NC_BUSYBOX=""
for _nc_bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
    if [ -x "$_nc_bb" ]; then
        NC_BUSYBOX="$_nc_bb"
        break
    fi
done
# 自动化测试/调试可覆盖
[ -n "${NC_BUSYBOX_OVERRIDE:-}" ] && NC_BUSYBOX="$NC_BUSYBOX_OVERRIDE"
unset _nc_bb

NC_CURL=""
command -v curl >/dev/null 2>&1 && NC_CURL="$(command -v curl)"
NC_WGET=""
command -v wget >/dev/null 2>&1 && NC_WGET="$(command -v wget)"
NC_BB_WGET=""
if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" --list 2>/dev/null | grep -qx wget; then
    NC_BB_WGET="$NC_BUSYBOX wget"
fi

# ---------- 输出 ----------
nc_now() { date +%s 2>/dev/null || echo 0; }

# 日志统一写 stderr：stdout 只用于 JSON / 文件内容 / 命令结果
nc_log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" >&2
}
nc_info() { nc_log "[Info] $*"; }
nc_warn() { nc_log "[Warn] $*"; }
nc_err()  { nc_log "[Error] $*"; }
nc_step() { printf '\n== %s ==\n' "$*" >&2; }
nc_die()  { nc_err "$*"; exit 1; }

# ---------- JSON ----------
# 输入一段文本，输出可嵌入 JSON 字符串的转义内容（不含首尾引号）
nc_json_escape() {
    printf '%s' "$1" | tr -d '\r' | awk '
        BEGIN { ORS = "" }
        NR > 1 { print "\\n" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            print
        }'
}

# 状态 JSON 的快速转义：大多数路径/版本/URL 不含引号/反斜杠，
# 避免为每个字段启动 tr/awk（Android 上进程启动开销很大）
nc_json_safe() {
    case "$1" in
        *'"'*|*'\\'*) nc_json_escape "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# true/false 标准化
nc_bool() {
    if [ "$1" = "true" ] || [ "$1" = "1" ] || [ "$1" = "yes" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# 读取一个简单键值（从 shell 变量文件），不执行文件
# $1=文件 $2=键
nc_conf_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^[[:space:]]*$2=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "$1" | tail -n 1
}

# ---------- 文件 ----------
nc_file_size() {
    [ -f "$1" ] || { echo 0; return 0; }
    wc -c <"$1" 2>/dev/null | tr -d ' \r\n'
}

nc_human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.1f KB", b / 1024
        else printf "%d B", b
    }' 2>/dev/null || echo "${1:-0} B"
}

nc_tail_log() {
    local _f _n
    _f=$1
    _n=${2:-60}
    [ -f "$_f" ] || return 0
    tail -n "$_n" "$_f" 2>/dev/null
}

nc_rotate_log() {
    local _log
    _log=$1
    [ -f "$_log" ] || return 0
    [ "$(nc_file_size "$_log")" -gt 262144 ] 2>/dev/null || return 0
    mv -f "$_log" "$_log.1" 2>/dev/null
}

# ---------- 目录初始化 ----------
nc_ensure_dirs() {
    mkdir -p "$NC_BIN" "$NC_SB" "$NC_MH" "$NC_SUB_DATA" "$NC_SUB_FE" \
        "$NC_RUN" "$NC_TASKS" "$NC_TMP" "$NC_BACKUP" "$NC_WIFI_DIR" 2>/dev/null
    chmod 700 "$NC_DATA" 2>/dev/null
    chmod 700 "$NC_RUN" "$NC_TASKS" "$NC_TMP" "$NC_WIFI_DIR" 2>/dev/null
}

# ---------- 设置 ----------
nc_load_settings() {
    local _k _v
    NC_ACTIVE_CORE="$NC_DEF_ACTIVE_CORE"
    NC_AUTO_START="$NC_DEF_AUTO_START"
    NC_SUB_AUTO_START="$NC_DEF_SUB_AUTO_START"
    NC_GH_PROXY="$NC_DEF_GH_PROXY"
    NC_SB_CHANNEL="$NC_DEF_SB_CHANNEL"
    NC_MH_CHANNEL="$NC_DEF_MH_CHANNEL"
        NC_WIFI_GUARD="$NC_DEF_WIFI_GUARD"
    NC_HOTSPOT_ENABLED="$NC_DEF_HOTSPOT_ENABLED"
    NC_HOTSPOT_USB="$NC_DEF_HOTSPOT_USB"

    if [ -f "$NC_SETTINGS" ]; then
        # 单次 shell 内建 read，避免每个键启动一次 sed
        while IFS='=' read -r _k _v; do
            _v=${_v#\"}
            _v=${_v%\"}
            case "$_k" in
                ACTIVE_CORE) NC_ACTIVE_CORE="$_v" ;;
                AUTO_START) NC_AUTO_START="$_v" ;;
                SUBSTORE_AUTO_START) NC_SUB_AUTO_START="$_v" ;;
                GH_PROXY) NC_GH_PROXY="$_v" ;;
                SINGBOX_CHANNEL) NC_SB_CHANNEL="$_v" ;;
                MIHOMO_CHANNEL) NC_MH_CHANNEL="$_v" ;;
                WIFI_GUARD) NC_WIFI_GUARD="$_v" ;;
                HOTSPOT_ENABLED) NC_HOTSPOT_ENABLED="$_v" ;;
                HOTSPOT_USB) NC_HOTSPOT_USB="$_v" ;;
            esac
        done <"$NC_SETTINGS"
    fi

    case "$NC_ACTIVE_CORE" in
        sing-box|mihomo) ;;
        *) NC_ACTIVE_CORE="$NC_DEF_ACTIVE_CORE" ;;
    esac
    case "$NC_AUTO_START" in true|false) ;; *) NC_AUTO_START="$NC_DEF_AUTO_START" ;; esac
    case "$NC_SUB_AUTO_START" in true|false) ;; *) NC_SUB_AUTO_START="$NC_DEF_SUB_AUTO_START" ;; esac
    case "$NC_SB_CHANNEL" in stable|alpha) ;; *) NC_SB_CHANNEL="$NC_DEF_SB_CHANNEL" ;; esac
    case "$NC_MH_CHANNEL" in stable|alpha) ;; *) NC_MH_CHANNEL="$NC_DEF_MH_CHANNEL" ;; esac
    case "$NC_WIFI_GUARD" in true|false) ;; *) NC_WIFI_GUARD="$NC_DEF_WIFI_GUARD" ;; esac
    case "$NC_HOTSPOT_ENABLED" in true|false) ;; *) NC_HOTSPOT_ENABLED="$NC_DEF_HOTSPOT_ENABLED" ;; esac
    case "$NC_HOTSPOT_USB" in true|false) ;; *) NC_HOTSPOT_USB="$NC_DEF_HOTSPOT_USB" ;; esac
    [ -z "$NC_GH_PROXY" ] && NC_GH_PROXY=""
    return 0
}

nc_save_settings() {
    local _tmp
    _tmp="$NC_SETTINGS.tmp.$$"
    {
        printf 'ACTIVE_CORE="%s"\n' "$NC_ACTIVE_CORE"
        printf 'AUTO_START="%s"\n' "$NC_AUTO_START"
        printf 'SUBSTORE_AUTO_START="%s"\n' "$NC_SUB_AUTO_START"
        printf 'GH_PROXY="%s"\n' "$NC_GH_PROXY"
        printf 'SINGBOX_CHANNEL="%s"\n' "$NC_SB_CHANNEL"
        printf 'MIHOMO_CHANNEL="%s"\n' "$NC_MH_CHANNEL"
        printf 'WIFI_GUARD="%s"\n' "$NC_WIFI_GUARD"
        printf 'HOTSPOT_ENABLED="%s"\n' "$NC_HOTSPOT_ENABLED"
        printf 'HOTSPOT_USB="%s"\n' "$NC_HOTSPOT_USB"
    } >"$_tmp" 2>/dev/null || return 1
    chmod 600 "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$NC_SETTINGS" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    return 0
}

# ---------- 下载 ----------
# 去掉前缀斜杠并把代理拼到完整 URL 前面（gh-proxy 等服务的格式）
nc_proxy_url() {
    local _base _url
    _url=$1
    [ -n "$NC_GH_PROXY" ] || { printf '%s' "$_url"; return 0; }
    _base="${NC_GH_PROXY%/}"
    case "$_url" in
        "$_base"/*)
            printf '%s' "$_url"
            ;;
        https://github.com/*|https://www.github.com/*|https://codeload.github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*|https://gist.github.com/*|https://gist.githubusercontent.com/*|https://objects.githubusercontent.com/*|https://github-releases.githubusercontent.com/*|https://media.githubusercontent.com/*|https://*.githubusercontent.com/*)
            printf '%s/%s' "$_base" "$_url"
            ;;
        *)
            printf '%s' "$_url"
            ;;
    esac
}

# 下载一个 URL 到目标文件；成功返回 0。日志写 stdout，便于任务日志展示。
nc_try_download() {
    local _max _out _retry _url
    _url=$1
    _out=$2
    _max=${NC_DL_MAX_TIME:-900}
    _retry=${NC_DL_RETRY:-2}
    rm -f "$_out" 2>/dev/null

    if [ -n "$NC_CURL" ]; then
        if "$NC_CURL" -fL --connect-timeout 10 --max-time "$_max" --retry "$_retry" --retry-delay 2 \
            -o "$_out" "$_url" 2>/dev/null && [ "$(nc_file_size "$_out")" -gt 0 ]; then
            return 0
        fi
        rm -f "$_out" 2>/dev/null
    fi

    if [ -n "$NC_WGET" ]; then
        if "$NC_WGET" -q -O "$_out" "$_url" 2>/dev/null && [ "$(nc_file_size "$_out")" -gt 0 ]; then
            return 0
        fi
        rm -f "$_out" 2>/dev/null
    fi

    if [ -n "$NC_BB_WGET" ]; then
        # shellcheck disable=SC2086
        if $NC_BB_WGET -q -O "$_out" "$_url" 2>/dev/null && [ "$(nc_file_size "$_out")" -gt 0 ]; then
            return 0
        fi
        rm -f "$_out" 2>/dev/null
    fi

    return 1
}

# 下载到目标文件：优先代理，失败后直连
nc_download() {
    local _dest _part _proxy_url _url
    _url=$1
    _dest=$2
    _part="$NC_TMP/download.$$.part"
    mkdir -p "$NC_TMP" 2>/dev/null

    _proxy_url=$(nc_proxy_url "$_url")
    if [ "$_proxy_url" != "$_url" ]; then
        nc_info "下载(加速): $_url"
        if nc_try_download "$_proxy_url" "$_part"; then
            mv -f "$_part" "$_dest" 2>/dev/null && return 0
        fi
        nc_warn "加速下载失败，尝试直连"
    else
        nc_info "下载: $_url"
    fi

    if nc_try_download "$_url" "$_part"; then
        mv -f "$_part" "$_dest" 2>/dev/null && return 0
    fi

    rm -f "$_part" 2>/dev/null
    nc_err "下载失败: $_url"
    return 1
}

# 抓取文件：直连优先，失败再走加速；供 Atom / HTML / JSON 解析使用
nc_try_fetch_file() {
    local _dest _timeout _url
    _url=$1
    _dest=$2
    _timeout=$3
    if [ -n "$NC_CURL" ]; then
        if "$NC_CURL" -fsSL --connect-timeout 8 --max-time "$_timeout" -o "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]; then
            return 0
        fi
        rm -f "$_dest" 2>/dev/null
    fi
    if [ -n "$NC_WGET" ]; then
        if "$NC_WGET" -q -O "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]; then
            return 0
        fi
        rm -f "$_dest" 2>/dev/null
    fi
    if [ -n "$NC_BB_WGET" ]; then
        # shellcheck disable=SC2086
        if $NC_BB_WGET -q -O "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]; then
            return 0
        fi
        rm -f "$_dest" 2>/dev/null
    fi
    return 1
}

nc_fetch_file() {
    local _dest _proxy_url _timeout _url
    _url=$1
    _dest=$2
    _timeout=${3:-25}
    mkdir -p "$NC_TMP" 2>/dev/null
    _proxy_url=$(nc_proxy_url "$_url")

    if nc_try_fetch_file "$_url" "$_dest" "$_timeout"; then
        return 0
    fi
    if [ "$_proxy_url" != "$_url" ] && nc_try_fetch_file "$_proxy_url" "$_dest" "$_timeout"; then
        return 0
    fi
    rm -f "$_dest" 2>/dev/null
    return 1
}

# 抓取文本：先直连，失败再走加速；不打印进度到 stdout
nc_fetch_text() {
    local _tmp _url
    _url=$1
    _tmp="$NC_TMP/fetch.$$.txt"
    nc_fetch_file "$_url" "$_tmp" "${2:-20}" || return 1
    cat "$_tmp"
    rm -f "$_tmp" 2>/dev/null
    return 0
}

# GitHub releases Atom feed 解析：避免 560KB release HTML 进入 argv 触发
# "Argument list too long"（Android /system/bin/printf 限制）
nc_github_atom_tag() {
    local _channel _file _repo _tag _tags
    _repo=$1
    _channel=${2:-any}
    _file="$NC_TMP/atom.$$.xml"
    if ! nc_fetch_file "https://github.com/$_repo/releases.atom" "$_file" 25; then
        rm -f "$_file" 2>/dev/null
        return 1
    fi
    _tags=$(awk '
        /<entry>/ { in_entry = 1; next }
        in_entry && /<title>/ {
            line = $0
            sub(/.*<title>/, "", line)
            sub(/<\/title>.*/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line != "") print line
            in_entry = 0
        }' "$_file" 2>/dev/null)
    rm -f "$_file" 2>/dev/null
    [ -n "$_tags" ] || return 1
    case "$_channel" in
        alpha)
            _tag=$(printf '%s\n' "$_tags" | grep -iE 'alpha' | head -n 1)
            ;;
        stable)
            _tag=$(printf '%s\n' "$_tags" | grep -viE 'alpha|beta|rc|pre' | head -n 1)
            ;;
        *)
            _tag=$(printf '%s\n' "$_tags" | head -n 1)
            ;;
    esac
    [ -n "$_tag" ] || return 1
    printf '%s' "$_tag"
}

# ---------- 解压 ----------
nc_tar_xzf() {
    # Android toybox tar 没有 xz 时可能返回 0 但一个文件都不解压；优先 busybox
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" tar -xzf "$1" -C "$2" 2>/dev/null; then
        return 0
    fi
    tar -xzf "$1" -C "$2" 2>/dev/null && return 0
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" gzip -dc "$1" 2>/dev/null | "$NC_BUSYBOX" tar -xf - -C "$2" 2>/dev/null; then
        return 0
    fi
    return 1
}

nc_tar_xJf() {
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" tar -xJf "$1" -C "$2" 2>/dev/null; then
        return 0
    fi
    tar -xJf "$1" -C "$2" 2>/dev/null && return 0
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" unxz -c "$1" 2>/dev/null | "$NC_BUSYBOX" tar -xf - -C "$2" 2>/dev/null; then
        return 0
    fi
    return 1
}

nc_unzip() {
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" unzip -q -o "$1" -d "$2" 2>/dev/null; then
        return 0
    fi
    unzip -q -o "$1" -d "$2" 2>/dev/null && return 0
    return 1
}

nc_gunzip() {
    if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" gzip -dc "$1" >"$2" 2>/dev/null; then
        return 0
    fi
    gzip -dc "$1" >"$2" 2>/dev/null && return 0
    return 1
}

nc_b64decode() {
    base64 -d 2>/dev/null && return 0
    [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" base64 -d 2>/dev/null && return 0
    return 1
}

# ---------- 随机 ----------
nc_random_path() {
    local _i _len _out
    _len=$((20 + $(date +%s) % 5))
    _out=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$_len" 2>/dev/null)
    if [ "${#_out}" -ne "$_len" ]; then
        _out=""
        _i=0
        while [ "$_i" -lt "$_len" ]; do
            _out="$_out$(printf '%s' "$(date +%s)$_i$RANDOM" | md5sum 2>/dev/null | cut -c1)"
            _i=$((_i + 1))
        done
    fi
    # 极端情况下 /dev/urandom 不可用，退化为时间戳+PID
    if [ -z "$_out" ]; then
        _out="$(date +%s)$$"
        while [ "${#_out}" -lt "$_len" ]; do
            _out="${_out}0123456789"
        done
        _out=$(printf '%s' "$_out" | cut -c1-"$_len")
    fi
    printf '/%s' "$_out"
}

nc_random_id() {
    local _out
    _out=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 2>/dev/null)
    [ -n "$_out" ] || _out="$$$(date +%s)"
    printf '%s-%s' "$(date +%s)" "$_out"
}

# 优先用 busybox find，避免部分 Android toybox find/参数差异
nc_find_file() {
    local _dir _name
    _dir=$1
    _name=$2
    if [ -n "$NC_BUSYBOX" ]; then
        "$NC_BUSYBOX" find "$_dir" -type f -name "$_name" 2>/dev/null | head -n 1
        return 0
    fi
    find "$_dir" -type f -name "$_name" 2>/dev/null | head -n 1
}

# ---------- PID ----------
nc_pid_alive() {
    [ -n "$1" ] || return 1
    kill -0 "$1" 2>/dev/null
}

# 状态展示用：只信任 pid 文件 + kill -0，避免每次 status 启动 pgrep/tr
nc_pidfile_alive() {
    local _p
    [ -f "$1" ] || return 1
    IFS= read -r _p <"$1" 2>/dev/null
    [ -n "$_p" ] || return 1
    nc_pid_alive "$_p"
}

nc_pidfile_pid() {
    local _p
    [ -f "$1" ] || return 1
    IFS= read -r _p <"$1" 2>/dev/null
    [ -n "$_p" ] || return 1
    nc_pid_alive "$_p" || return 1
    printf '%s' "$_p"
}

nc_cmdline() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null
}

nc_pid_matches() {
    local _cmdline _needle _pid
    _pid=$1
    _needle=$2
    [ -n "$_pid" ] || return 1
    [ -n "$_needle" ] || return 1
    case "$_pid" in *[!0-9]*) return 1 ;; esac
    [ "$_pid" -gt 0 ] || return 1
    # 永远不要把自己/父 shell 当成目标进程
    [ "$_pid" = "$$" ] && return 1
    [ "$_pid" = "$PPID" ] && return 1
    nc_pid_alive "$_pid" || return 1
    _cmdline=$(nc_cmdline "$_pid")
    case "$_cmdline" in
        *pgrep*|*" grep "*|*/grep\ *|*"ps -A"*|*"ps -ef"*)
            return 1
            ;;
    esac
    case "$_cmdline" in
        *"$_needle"*) return 0 ;;
    esac
    return 1
}

nc_pids_by_name() {
    pidof "$1" 2>/dev/null
}

nc_pids_by_pattern() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$1" 2>/dev/null
        return 0
    fi
    ps -A -o pid,args 2>/dev/null | grep -F "$1" | grep -v grep | awk '{print $1}'
}

nc_first_pid() {
    local _out
    _out=$(nc_pids_by_pattern "$1" 2>/dev/null | head -n 1 | tr -d ' \r\n')
    [ -n "$_out" ] && printf '%s' "$_out"
}

nc_stop_pid() {
    local _i _pid
    _pid=$1
    nc_pid_alive "$_pid" || return 0
    kill -TERM "$_pid" 2>/dev/null
    _i=0
    while nc_pid_alive "$_pid" && [ "$_i" -lt 25 ]; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    if nc_pid_alive "$_pid"; then
        kill -KILL "$_pid" 2>/dev/null
        sleep 0.3 2>/dev/null || sleep 1
    fi
    return 0
}

# ---------- 进程启动 ----------
nc_detach_root() {
    local _cg
    for _cg in /sys/fs/cgroup/cgroup.procs /dev/cg2_bpf/cgroup.procs /dev/cpuctl/tasks /dev/stune/tasks; do
        [ -f "$_cg" ] && { echo $$ >"$_cg"; } 2>/dev/null
    done
    { echo -1000 >"/proc/$$/oom_score_adj"; } 2>/dev/null
    unset _cg
}

# 仅启动并脱离，不校验进程是否存活（适合短任务 / worker）
# $1=日志 $2=pid 文件，其余=命令
nc_spawn_detached() {
    local _log _pid _pidfile
    _log=$1
    _pidfile=$2
    shift 2
    mkdir -p "$(dirname "$_log")" "$(dirname "$_pidfile")" 2>/dev/null
    nc_detach_root
    (
        cd / 2>/dev/null || true
        ulimit -n 65535 2>/dev/null || true
        if [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" --list 2>/dev/null | grep -qx setsid; then
            exec "$NC_BUSYBOX" setsid "$@"
        elif command -v setsid >/dev/null 2>&1; then
            exec setsid "$@"
        elif [ -n "$NC_BUSYBOX" ]; then
            exec "$NC_BUSYBOX" nohup "$@"
        else
            exec nohup "$@"
        fi
    ) </dev/null >>"$_log" 2>&1 &
    _pid=$!
    echo "$_pid" >"$_pidfile" 2>/dev/null
    return 0
}

# 启动一个长期服务并校验进程存活
# $1=日志 $2=pid 文件 $3=oom_score_adj $4=用于兜底查找的 cmdline 片段
# 其余参数=命令
nc_launch() {
    local _i _log _oom _pattern _pid _pidfile
    _log=$1
    _pidfile=$2
    _oom=$3
    _pattern=$4
    shift 4

    nc_rotate_log "$_log"
    nc_spawn_detached "$_log" "$_pidfile" "$@"

    # 尽早确认 pid，而不是每次固定等待 0.8s。
    # 进程通常 100–300ms 内 exec 完成；慢设备最多等约 1.2s。
    _i=0
    _pid=""
    while [ "$_i" -lt 12 ]; do
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$_pid" ] && nc_pid_matches "$_pid" "$_pattern"; then
            break
        fi
        _pid=""
        sleep 0.1 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done

    if [ -z "$_pid" ]; then
        _pid=$(nc_first_pid "$_pattern")
    fi
    if [ -n "$_pid" ]; then
        echo "$_pid" >"$_pidfile" 2>/dev/null
        { echo "$_oom" >"/proc/$_pid/oom_score_adj"; } 2>/dev/null
        return 0
    fi
    rm -f "$_pidfile" 2>/dev/null
    return 1
}

# ---------- 设备 / 架构 ----------
nc_prop() {
    getprop "$1" 2>/dev/null | tr -d '\r\n'
}

nc_arch() {
    local _abi
    _abi=$(nc_prop ro.product.cpu.abi)
    [ -n "$_abi" ] || _abi=$(uname -m 2>/dev/null)
    NC_ABI="$_abi"
    case "$_abi" in
        arm64-v8a|aarch64)
            NC_SB_ARCH="arm64"; NC_MH_ARCH="arm64-v8"; NC_NODE_ARCH="arm64" ;;
        armeabi-v7a|armeabi|armv7*|armv8l)
            NC_SB_ARCH="arm"; NC_MH_ARCH="armv7"; NC_NODE_ARCH="arm" ;;
        x86_64|amd64)
            NC_SB_ARCH="amd64"; NC_MH_ARCH="amd64"; NC_NODE_ARCH="x64" ;;
        x86|i386|i686)
            NC_SB_ARCH="386"; NC_MH_ARCH="386"; NC_NODE_ARCH="ia32" ;;
        *)
            NC_SB_ARCH="arm64"; NC_MH_ARCH="arm64-v8"; NC_NODE_ARCH="arm64" ;;
    esac
}

nc_manager() {
    if [ -d /data/adb/ksu ]; then
        printf 'KernelSU'
    elif [ -d /data/adb/ap ]; then
        printf 'APatch'
    elif [ -d /data/adb/magisk ]; then
        printf 'Magisk'
    else
        printf 'Unknown'
    fi
}

nc_module_version() {
    [ -f "$NC_MODULE_PROP" ] || { printf 'unknown'; return 0; }
    sed -n 's/^version=//p' "$NC_MODULE_PROP" | head -n 1 | tr -d '\r\n'
}

nc_module_version_code() {
    [ -f "$NC_MODULE_PROP" ] || { printf '0'; return 0; }
    sed -n 's/^versionCode=//p' "$NC_MODULE_PROP" | head -n 1 | tr -d '\r\n'
}

# ---------- 初始化 ----------
nc_init() {
    nc_ensure_dirs
    nc_load_settings
    nc_arch
} 
