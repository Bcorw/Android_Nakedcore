#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 精简版 Sub-Store 管理
# 只保留前后端、Node、合并端口、访问路径与更新，不引入 http-meta
# ============================================================

nc_sub_pidfile()  { printf '%s/sub-store.pid' "$NC_RUN"; }
nc_sub_log()      { printf '%s/substore.log' "$NC_RUN"; }
nc_sub_started()  { printf '%s/substore.started' "$NC_RUN"; }
nc_sub_backend_version_file()  { printf '%s/backend_version' "$NC_SUB"; }
NC_SUB_ENV_LOADED="${NC_SUB_ENV_LOADED:-0}"
NC_SUB_NODE_CACHE="${NC_SUB_NODE_CACHE:-}"
nc_sub_frontend_version_file() { printf '%s/frontend_version' "$NC_SUB"; }

# 默认环境变量文件（首次安装/文件丢失时）
nc_sub_ensure_env() {
    local _path
    [ -f "$NC_SUB_ENV" ] && return 0
    mkdir -p "$NC_SUB" "$NC_SUB_DATA" "$NC_SUB_FE" 2>/dev/null
    _path=$(nc_random_path)
    cat >"$NC_SUB_ENV" <<EOF
# ============================================================
# Sub-Store 环境变量（由 Android Nakedcore 管理）
# 修改后重启 Sub-Store 生效；合并模式只需一个端口
# 变量与官方 Docker 版保持一致
# ============================================================

# 后端监听地址；0.0.0.0 表示允许局域网访问（有安全风险）
SUB_STORE_BACKEND_API_HOST="127.0.0.1"
SUB_STORE_BACKEND_API_PORT="3000"

# 后端随机访问路径（首次安装自动生成；泄露后可在 WebUI 重新生成）
SUB_STORE_FRONTEND_BACKEND_PATH="$_path"

# 前端静态文件与数据目录
SUB_STORE_FRONTEND_PATH="$NC_SUB_FE"
SUB_STORE_DATA_BASE_PATH="$NC_SUB_DATA"

# 合并模式：后端同时提供前端页面与 API（推荐）
# 关闭时改为前后端分离：注释或把值改成 "false" 后填写前端端口
SUB_STORE_BACKEND_MERGE="true"
SUB_STORE_FRONTEND_HOST="127.0.0.1"
SUB_STORE_FRONTEND_PORT="3001"

# 请求限制与 CORS
SUB_STORE_BODY_JSON_LIMIT="1mb"
SUB_STORE_MAX_HEADER_SIZE="32768"
SUB_STORE_CORS_ALLOWED_ORIGINS="*"

# 可选：默认代理、定时同步、推送、MMDB
# SUB_STORE_BACKEND_DEFAULT_PROXY="socks5://127.0.0.1:7890"
# SUB_STORE_BACKEND_SYNC_CRON=""
# SUB_STORE_PUSH_SERVICE=""
# SUB_STORE_MMDB_COUNTRY_PATH=""
# SUB_STORE_MMDB_COUNTRY_URL=""
# SUB_STORE_MMDB_ASN_PATH=""
# SUB_STORE_MMDB_ASN_URL=""
# SUB_STORE_MMDB_CRON=""
EOF
    chmod 600 "$NC_SUB_ENV" 2>/dev/null
    NC_SUB_ENV_LOADED=0
    nc_info "已创建 Sub-Store 环境变量文件: $NC_SUB_ENV"
}

# 读取 env 到 NC_SUB_* 变量；不执行到当前 shell（子 shell 内 source）
nc_sub_load_env() {
    local _merge _vals
    if [ "${NC_SUB_ENV_LOADED:-0}" = "1" ]; then
        return 0
    fi
    NC_SUB_HOST="127.0.0.1"
    NC_SUB_PORT="3000"
    NC_SUB_FRONT_HOST="127.0.0.1"
    NC_SUB_FRONT_PORT="3001"
    NC_SUB_MERGE="true"
    NC_SUB_PATH=""
    NC_SUB_DATA_PATH="$NC_SUB_DATA"
    NC_SUB_FE_PATH="$NC_SUB_FE"
    NC_SUB_ENV_VALID=1
    NC_SUB_ENV_ERROR=""

    [ -f "$NC_SUB_ENV" ] || { NC_SUB_ENV_LOADED=1; return 0; }

    if ! sh -n "$NC_SUB_ENV" 2>/dev/null; then
        NC_SUB_ENV_VALID=0
        NC_SUB_ENV_ERROR="环境变量文件存在语法错误"
        NC_SUB_ENV_LOADED=1
        return 0
    fi

    _vals=$(
        sub_store_path="$NC_SUB"
        run_path="$NC_RUN"
        # shellcheck disable=SC1090
        . "$NC_SUB_ENV" >/dev/null 2>&1
        _merge="${SUB_STORE_BACKEND_MERGE:-true}"
        case "$_merge" in true|1|yes|TRUE|True) _merge="true" ;; *) _merge="false" ;; esac
        printf '%s\n' \
            "${SUB_STORE_BACKEND_API_HOST:-127.0.0.1}" \
            "${SUB_STORE_BACKEND_API_PORT:-3000}" \
            "${SUB_STORE_FRONTEND_HOST:-127.0.0.1}" \
            "${SUB_STORE_FRONTEND_PORT:-3001}" \
            "$_merge" \
            "${SUB_STORE_FRONTEND_BACKEND_PATH:-}" \
            "${SUB_STORE_DATA_BASE_PATH:-$NC_SUB_DATA}" \
            "${SUB_STORE_FRONTEND_PATH:-$NC_SUB_FE}"
    ) 2>/dev/null

    # 用 shell 内建 read 一次取 8 行，避免 8 次 sed
    {
        IFS= read -r NC_SUB_HOST
        IFS= read -r NC_SUB_PORT
        IFS= read -r NC_SUB_FRONT_HOST
        IFS= read -r NC_SUB_FRONT_PORT
        IFS= read -r NC_SUB_MERGE
        IFS= read -r NC_SUB_PATH
        IFS= read -r NC_SUB_DATA_PATH
        IFS= read -r NC_SUB_FE_PATH
    } <<EOF
$_vals
EOF

    # 基础清洗
    [ -n "$NC_SUB_HOST" ] || NC_SUB_HOST="127.0.0.1"
    [ -n "$NC_SUB_FRONT_HOST" ] || NC_SUB_FRONT_HOST="$NC_SUB_HOST"
    case "$NC_SUB_PORT" in *[!0-9]*|"") NC_SUB_PORT="3000" ;; esac
    case "$NC_SUB_FRONT_PORT" in *[!0-9]*|"") NC_SUB_FRONT_PORT="3001" ;; esac
    [ "$NC_SUB_MERGE" = "true" ] || NC_SUB_MERGE="false"
    [ -n "$NC_SUB_DATA_PATH" ] || NC_SUB_DATA_PATH="$NC_SUB_DATA"
    [ -n "$NC_SUB_FE_PATH" ] || NC_SUB_FE_PATH="$NC_SUB_FE"
    NC_SUB_ENV_LOADED=1
    return 0
}

# 判断 Sub-Store 是否可启动，输出原因
nc_sub_health_reason() {
    nc_sub_load_env
    if [ "$NC_SUB_ENV_VALID" != "1" ]; then
        printf '%s' "$NC_SUB_ENV_ERROR"
        return 1
    fi
    if [ "$NC_SUB_MERGE" = "true" ]; then
        if [ -z "$NC_SUB_PATH" ]; then
            printf '缺少访问路径'
            return 1
        fi
        case "$NC_SUB_PATH" in
            /*) ;;
            *) printf '访问路径必须以 / 开头'; return 1 ;;
        esac
    fi
    if [ -z "$(nc_sub_node)" ]; then
        printf '缺少 Node 运行环境'
        return 1
    fi
    if [ ! -f "$NC_SUB_BUNDLE" ]; then
        printf '缺少 Sub-Store 后端'
        return 1
    fi
    if [ ! -f "$NC_SUB_FE_PATH/index.html" ]; then
        printf '缺少 Sub-Store 前端'
        return 1
    fi
    printf '正常'
    return 0
}

nc_sub_healthy() {
    local _reason
    _reason=$(nc_sub_health_reason)
    [ "$_reason" = "正常" ]
}

# Node 探测：偏好模块自管理的 node，其次兼容 Termux / Sub-Store 模块
nc_sub_node() {
    local _n _which
    if [ -n "${NC_SUB_NODE_CACHE:-}" ] && [ -x "$NC_SUB_NODE_CACHE" ]; then
        printf '%s' "$NC_SUB_NODE_CACHE"
        return 0
    fi
    for _n in \
        "$NC_NODE_BIN" \
        "$NC_SUB/bin/node" \
        "/data/local/sub_store/bin/sub_store_node" \
        "/data/data/com.termux/files/usr/bin/node" \
        "/data/adb/modules/Sub-Store/bin/node" \
        "/system/bin/node"; do
        if [ -x "$_n" ]; then
            NC_SUB_NODE_CACHE="$_n"
            printf '%s' "$_n"
            return 0
        fi
    done
    _which=$(command -v node 2>/dev/null)
    if [ -n "$_which" ] && [ -x "$_which" ]; then
        NC_SUB_NODE_CACHE="$_which"
        printf '%s' "$_which"
        return 0
    fi
    return 1
}

nc_sub_node_version() {
    local _node _v
    _node=$(nc_sub_node) || return 1
    # 自管理 Node：版本文件已由更新流程写入，避免每次 status 启动 100MB+ 的 node
    if [ "$_node" = "$NC_NODE_BIN" ] && [ -f "$NC_BIN/node_version" ]; then
        IFS= read -r _v <"$NC_BIN/node_version" 2>/dev/null
        [ -n "$_v" ] && { printf '%s' "${_v#v}"; return 0; }
    fi
    "$_node" --version 2>/dev/null | sed 's/^v//' | tr -d '\r\n'
}

nc_sub_backend_version() {
    local _f _v
    _f=$(nc_sub_backend_version_file)
    if [ -f "$_f" ]; then
        IFS= read -r _v <"$_f" 2>/dev/null
        printf '%s' "${_v%\r}"
        return 0
    fi
    [ -f "$NC_SUB_BUNDLE" ] || return 0
    sed -n 's/.*SUB_STORE_BACKEND_VERSION: //p' "$NC_SUB_BUNDLE" 2>/dev/null | head -n 1 | tr -d '\r\n'
}

nc_sub_frontend_version() {
    local _f _v
    _f=$(nc_sub_frontend_version_file)
    if [ -f "$_f" ]; then
        IFS= read -r _v <"$_f" 2>/dev/null
        printf '%s' "${_v%\r}"
        return 0
    fi
    [ -f "$NC_SUB_FE/index.html" ] || return 0
    sed -n 's/.*<meta name="version" content="\([^"]*\)".*/\1/p' "$NC_SUB_FE/index.html" 2>/dev/null | head -n 1 | tr -d '\r\n'
}

nc_sub_running() {
    local _bundle _pid _pidfile
    _bundle="$NC_SUB_BUNDLE"
    _pidfile=$(nc_sub_pidfile)
    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$_bundle"; then
            return 0
        fi
    fi
    for _pid in $(nc_pids_by_pattern "$_bundle" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$_bundle"; then
            echo "$_pid" >"$_pidfile" 2>/dev/null
            return 0
        fi
    done
    return 1
}

nc_sub_pid() {
    local _pid _pidfile
    _pidfile=$(nc_sub_pidfile)
    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$NC_SUB_BUNDLE"; then
            printf '%s' "$_pid"
            return 0
        fi
    fi
    for _pid in $(nc_pids_by_pattern "$NC_SUB_BUNDLE" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$NC_SUB_BUNDLE"; then
            printf '%s' "$_pid"
            return 0
        fi
    done
    return 1
}

# 把 env 文件导出到当前 shell（调用后立即 nc_launch）
nc_sub_export_env() {
    set -a
    sub_store_path="$NC_SUB"
    run_path="$NC_RUN"
    # shellcheck disable=SC1090
    . "$NC_SUB_ENV" 2>/dev/null
    set +a

    export SUB_STORE_BACKEND_API_HOST="${SUB_STORE_BACKEND_API_HOST:-127.0.0.1}"
    export SUB_STORE_BACKEND_API_PORT="${SUB_STORE_BACKEND_API_PORT:-3000}"
    export SUB_STORE_FRONTEND_BACKEND_PATH="${SUB_STORE_FRONTEND_BACKEND_PATH:-}"
    export SUB_STORE_DATA_BASE_PATH="${SUB_STORE_DATA_BASE_PATH:-$NC_SUB_DATA}"
    export SUB_STORE_FRONTEND_PATH="${SUB_STORE_FRONTEND_PATH:-$NC_SUB_FE}"
    export SUB_STORE_FRONTEND_HOST="${SUB_STORE_FRONTEND_HOST:-$SUB_STORE_BACKEND_API_HOST}"
    export SUB_STORE_FRONTEND_PORT="${SUB_STORE_FRONTEND_PORT:-3001}"
    # Android 没有可写的 /tmp，Node 的 os.tmpdir() 需要指向模块运行目录
    export TMPDIR="$NC_TMP"
    export HOME="$NC_SUB"

    # Sub-Store 后端按“变量非空即合并”判断，false 必须不导出
    if [ "$NC_SUB_MERGE" != "true" ]; then
        unset SUB_STORE_BACKEND_MERGE
    else
        export SUB_STORE_BACKEND_MERGE="true"
    fi
    return 0
}

# 计算直达地址（合并模式单端口；分离模式走前端代理）
nc_sub_direct_url() {
    local _base _fhost _host
    nc_sub_load_env
    _host="$NC_SUB_HOST"
    case "$_host" in
        0.0.0.0|::|localhost) _host="127.0.0.1" ;;
    esac
    _fhost="$NC_SUB_FRONT_HOST"
    case "$_fhost" in
        0.0.0.0|::|localhost) _fhost="127.0.0.1" ;;
    esac

    if [ "$NC_SUB_MERGE" = "true" ]; then
        _base="http://$_host:$NC_SUB_PORT"
        if [ -n "$NC_SUB_PATH" ]; then
            printf '%s?api=%s%s' "$_base" "$_base" "$NC_SUB_PATH"
        else
            printf '%s' "$_base"
        fi
    else
        _base="http://$_fhost:$NC_SUB_FRONT_PORT"
        if [ -n "$NC_SUB_PATH" ]; then
            printf '%s?api=%s%s' "$_base" "$_base" "$NC_SUB_PATH"
        else
            printf '%s' "$_base"
        fi
    fi
}

nc_sub_start() {
    local _log _node _pid _pidfile _reason
    nc_sub_load_env
    if [ "$NC_SUB_ENV_VALID" != "1" ]; then
        nc_err "$NC_SUB_ENV_ERROR"
        return 1
    fi
    _reason=$(nc_sub_health_reason)
    if [ "$_reason" != "正常" ]; then
        nc_err "Sub-Store 无法启动: $_reason"
        return 1
    fi

    if nc_sub_running; then
        _pid=$(nc_sub_pid)
        nc_info "Sub-Store 已在运行 (PID: ${_pid:-?})"
        return 0
    fi

    _node=$(nc_sub_node)
    _log=$(nc_sub_log)
    _pidfile=$(nc_sub_pidfile)

    nc_sub_export_env
    # Termux 的 node 依赖 Termux 自带库
    case "$_node" in
        */com.termux/*)
            export LD_LIBRARY_PATH="/data/data/com.termux/files/usr/lib:${LD_LIBRARY_PATH:-}"
            ;;
    esac

    nc_info "启动 Sub-Store (Node: $_node)"
    nc_launch "$_log" "$_pidfile" -800 "$NC_SUB_BUNDLE" "$_node" "$NC_SUB_BUNDLE"

    if [ $? -ne 0 ] || ! nc_sub_running; then
        nc_err "Sub-Store 启动失败"
        nc_tail_log "$_log" 15
        return 1
    fi

    date '+%Y-%m-%d %H:%M:%S' >"$(nc_sub_started)" 2>/dev/null
    _pid=$(nc_sub_pid)
    nc_info "Sub-Store 启动成功 (PID: ${_pid:-?})"
    nc_info "访问地址: $(nc_sub_direct_url)"
    return 0
}

nc_sub_stop() {
    local _pid _pidfile _stopped
    _stopped=0
    _pidfile=$(nc_sub_pidfile)
    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$NC_SUB_BUNDLE"; then
            nc_stop_pid "$_pid"
            _stopped=1
        fi
    fi
    for _pid in $(nc_pids_by_pattern "$NC_SUB_BUNDLE" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$NC_SUB_BUNDLE"; then
            nc_stop_pid "$_pid"
            _stopped=1
        fi
    done
    rm -f "$_pidfile" "$(nc_sub_started)" 2>/dev/null
    if [ "$_stopped" = "1" ]; then
        nc_info "Sub-Store 已停止"
    else
        nc_info "Sub-Store 未在运行"
    fi
    return 0
}

nc_sub_restart() {
    local _reason
    # 先确认可启动，避免环境缺失时把正在运行的服务停掉
    _reason=$(nc_sub_health_reason)
    if [ "$_reason" != "正常" ]; then
        nc_err "Sub-Store 无法重启: $_reason"
        return 1
    fi
    nc_sub_stop >/dev/null 2>&1
    nc_sub_start
}

# 修改 env 中的单个键；值由调用方校验
nc_sub_env_set_raw() {
    local _key _tmp _value
    _key=$1
    _value=$2
    nc_sub_ensure_env
    _tmp="$NC_SUB_ENV.tmp.$$"
    awk -v k="$_key" -v v="$_value" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "=" {
            print k "=\"" v "\""
            done = 1
            next
        }
        { print }
        END {
            if (!done) print k "=\"" v "\""
        }' "$NC_SUB_ENV" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }

    if ! sh -n "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        nc_err "写入后的环境变量文件语法错误"
        return 1
    fi
    cp -f "$NC_SUB_ENV" "$NC_SUB_ENV.bak" 2>/dev/null
    chmod 600 "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$NC_SUB_ENV" 2>/dev/null || return 1
    NC_SUB_ENV_LOADED=0
    return 0
}

nc_sub_set() {
    local _key _value
    _key=$1
    _value=$2
    nc_sub_ensure_env
    case "$_key" in
        SUB_STORE_BACKEND_API_HOST|SUB_STORE_FRONTEND_HOST)
            case "$_value" in
                127.0.0.1|0.0.0.0|::|localhost) ;;
                *) nc_err "监听地址只能是 127.0.0.1 或 0.0.0.0"; return 1 ;;
            esac
            ;;
        SUB_STORE_BACKEND_API_PORT|SUB_STORE_FRONTEND_PORT)
            case "$_value" in
                *[!0-9]*|"") nc_err "端口必须是数字"; return 1 ;;
            esac
            [ "${#_value}" -le 5 ] || { nc_err "端口超出范围"; return 1; }
            [ "$_value" -ge 1024 ] && [ "$_value" -le 65535 ] || { nc_err "端口范围 1024-65535"; return 1; }
            ;;
        SUB_STORE_BACKEND_MERGE)
            case "$_value" in true|false) ;; *) nc_err "合并模式只能是 true 或 false"; return 1 ;; esac
            ;;
        SUB_STORE_FRONTEND_BACKEND_PATH)
            case "$_value" in
                /*) ;;
                *) nc_err "访问路径必须以 / 开头"; return 1 ;;
            esac
            case "$_value" in
                *[!A-Za-z0-9/_-]*) nc_err "访问路径只能包含字母、数字、/ _ -"; return 1 ;;
            esac
            [ "${#_value}" -le 80 ] || { nc_err "访问路径过长"; return 1; }
            ;;
        SUB_STORE_CORS_ALLOWED_ORIGINS)
            [ -n "$_value" ] || { nc_err "CORS 不能为空"; return 1; }
            ;;
        *)
            nc_err "不支持的 Sub-Store 配置项: $_key"
            return 1
            ;;
    esac

    nc_sub_env_set_raw "$_key" "$_value" || return 1
    nc_info "已写入 $_key=$_value"

    # 监听地址同时更新前端监听地址，方便分离模式
    case "$_key" in
        SUB_STORE_BACKEND_API_HOST)
            nc_sub_env_set_raw SUB_STORE_FRONTEND_HOST "$_value" >/dev/null 2>&1
            ;;
    esac
    return 0
}

nc_sub_regen_path() {
    local _new
    nc_sub_ensure_env
    _new=$(nc_random_path)
    nc_sub_set SUB_STORE_FRONTEND_BACKEND_PATH "$_new" || return 1
    nc_info "新的访问路径: $_new"
    if nc_sub_running; then
        nc_info "重启 Sub-Store 以应用新路径..."
        nc_sub_restart || return 1
    fi
    return 0
}

# ---------- Node 更新 ----------
nc_node_latest_lts() {
    local _file _ver
    _file="$NC_TMP/node-index.$$.json"
    if ! nc_fetch_file "https://nodejs.org/dist/index.json" "$_file" 30; then
        rm -f "$_file" 2>/dev/null
        return 1
    fi
    _ver=$(awk '
        BEGIN { RS = "}" }
        /"lts":"/ {
            line = $0
            sub(/.*"version":"/, "", line)
            sub(/".*/, "", line)
            print line
            exit
        }' "$_file" 2>/dev/null)
    rm -f "$_file" 2>/dev/null
    _ver=${_ver#v}
    [ -n "$_ver" ] || return 1
    printf '%s' "$_ver"
}

nc_node_asset() {
    # 输出: 版本号<TAB>下载 URL
    local _file _lts _major _majors _tag _ver
    _lts=$(nc_node_latest_lts) || _lts=""

    _majors=""
    [ -n "$_lts" ] && _majors="${_lts%%.*}"
    _majors="$_majors 24 22 26 25 23"
    _ver=""
    _major=""
    _file="$NC_TMP/node-assets.$$.html"

    for _major in $_majors; do
        _tag="node-android-${NC_NODE_ARCH}-${_major}"
        if ! nc_fetch_file "https://github.com/Delusions6515/node-android-build/releases/expanded_assets/${_tag}" "$_file" 25; then
            rm -f "$_file" 2>/dev/null
            continue
        fi
        _ver=$(grep -oE "node-android-${NC_NODE_ARCH}-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz" "$_file" 2>/dev/null \
            | sed 's/.*-\([0-9.]*\)\.tar\.xz/\1/' \
            | sort -u -t. -k1,1n -k2,2n -k3,3n \
            | tail -n 1)
        rm -f "$_file" 2>/dev/null
        [ -n "$_ver" ] && break
    done

    if [ -z "$_ver" ]; then
        [ -n "$_lts" ] || return 1
        _major="${_lts%%.*}"
        _ver="$_lts"
    fi
    [ -n "$_major" ] || _major="${_ver%%.*}"

    printf '%s\t%s\n' "$_ver" \
        "https://github.com/Delusions6515/node-android-build/releases/download/node-android-${NC_NODE_ARCH}-${_major}/node-android-${NC_NODE_ARCH}-${_ver}.tar.xz"
}

nc_node_update() {
    local _asset _current _found _target_ver _url _v _work
    _asset=$(nc_node_asset)
    if [ -z "$_asset" ]; then
        nc_err "无法获取 Node 最新版本（检查网络）"
        return 1
    fi
    _target_ver=$(printf '%s' "$_asset" | cut -f1)
    _url=$(printf '%s' "$_asset" | cut -f2)

    _current=""
    [ -x "$NC_NODE_BIN" ] && _current=$("$NC_NODE_BIN" --version 2>/dev/null | sed 's/^v//' | tr -d '\r\n')
    if [ "$_current" = "$_target_ver" ]; then
        nc_info "Node 已是最新版本: $_current"
        return 0
    fi

    nc_info "当前 Node: ${_current:-未安装}"
    nc_info "目标 Node: $_target_ver ($NC_NODE_ARCH)"

    _work="$NC_TMP/node-update-$$"
    rm -rf "$_work" 2>/dev/null
    mkdir -p "$_work" 2>/dev/null
    nc_download "$_url" "$_work/node.tar.xz" || { rm -rf "$_work"; return 1; }
    nc_tar_xJf "$_work/node.tar.xz" "$_work" || {
        nc_err "Node 解压失败（设备可能缺少 xz 支持）"
        rm -rf "$_work"
        return 1
    }
    _found=$(nc_find_file "$_work" node)
    if [ -z "$_found" ]; then
        nc_err "压缩包中未找到 node 二进制"
        rm -rf "$_work"
        return 1
    fi
    chmod 755 "$_found" 2>/dev/null
    _v=$("$_found" --version 2>/dev/null | tr -d '\r\n')
    if [ -z "$_v" ]; then
        nc_err "下载的 Node 无法执行"
        rm -rf "$_work"
        return 1
    fi

    [ -x "$NC_NODE_BIN" ] && cp -f "$NC_NODE_BIN" "$NC_NODE_BIN.old" 2>/dev/null
    cp -f "$_found" "$NC_NODE_BIN" 2>/dev/null || { nc_err "写入 Node 失败"; rm -rf "$_work"; return 1; }
    chmod 755 "$NC_NODE_BIN" 2>/dev/null
    printf '%s\n' "${_target_ver}" >"$NC_BIN/node_version" 2>/dev/null
    NC_SUB_NODE_CACHE=""
    rm -rf "$_work" 2>/dev/null
    nc_info "Node 已更新: $_v"
    return 0
}

# ---------- Sub-Store 更新 ----------
nc_sub_update_backend() {
    local _current _newver _size _tmp _url
    _url="https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js"
    _tmp="$NC_TMP/sub-store.bundle.js.new"
    rm -f "$_tmp" 2>/dev/null
    nc_download "$_url" "$_tmp" || return 1

    _size=$(nc_file_size "$_tmp")
    if [ "$_size" -lt 100000 ]; then
        nc_err "后端文件异常 (大小: $_size)"
        rm -f "$_tmp"
        return 1
    fi
    _newver=$(sed -n 's/.*SUB_STORE_BACKEND_VERSION: //p' "$_tmp" 2>/dev/null | head -n 1 | tr -d '\r\n')
    if [ -z "$_newver" ]; then
        nc_err "无法识别后端版本号"
        rm -f "$_tmp"
        return 1
    fi
    _current=$(nc_sub_backend_version)
    if [ "$_newver" = "$_current" ]; then
        nc_info "Sub-Store 后端已是最新版本: $_current"
        rm -f "$_tmp"
        return 0
    fi

    cp -f "$NC_SUB_BUNDLE" "$NC_SUB_BUNDLE.old" 2>/dev/null
    mv -f "$_tmp" "$NC_SUB_BUNDLE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 644 "$NC_SUB_BUNDLE" 2>/dev/null
    printf '%s\n' "$_newver" >"$(nc_sub_backend_version_file)" 2>/dev/null
    nc_info "Sub-Store 后端已更新: $_current -> $_newver"
    return 0
}

nc_sub_update_frontend() {
    local _current _dir _index _newver _size _src _url _zip
    _url="https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"
    _zip="$NC_TMP/substore-front.zip"
    _dir="$NC_TMP/substore-front.$$"
    rm -f "$_zip" 2>/dev/null
    rm -rf "$_dir" 2>/dev/null
    mkdir -p "$_dir" 2>/dev/null

    nc_download "$_url" "$_zip" || { rm -rf "$_dir"; return 1; }
    _size=$(nc_file_size "$_zip")
    if [ "$_size" -lt 100000 ]; then
        nc_err "前端压缩包异常 (大小: $_size)"
        rm -f "$_zip"; rm -rf "$_dir"
        return 1
    fi
    nc_unzip "$_zip" "$_dir" || {
        nc_err "前端解压失败"
        rm -f "$_zip"; rm -rf "$_dir"
        return 1
    }
    rm -f "$_zip" 2>/dev/null

    _src=""
    _index=$(find "$_dir" -type f -path '*/dist/index.html' 2>/dev/null | head -n 1)
    if [ -n "$_index" ]; then
        _src=$(dirname "$_index")
    else
        _index=$(find "$_dir" -type f -name index.html 2>/dev/null | head -n 1)
        [ -n "$_index" ] && _src=$(dirname "$_index")
    fi
    if [ -z "$_src" ] || [ ! -f "$_src/index.html" ]; then
        nc_err "前端压缩包中未找到 index.html"
        rm -rf "$_dir"
        return 1
    fi

    _newver=$(sed -n 's/.*<meta name="version" content="\([^"]*\)".*/\1/p' "$_src/index.html" 2>/dev/null | head -n 1 | tr -d '\r\n')
    _current=$(nc_sub_frontend_version)
    if [ -n "$_newver" ] && [ "$_newver" = "$_current" ]; then
        nc_info "Sub-Store 前端已是最新版本: $_current"
        rm -rf "$_dir"
        return 0
    fi

    rm -rf "$NC_SUB_FE.old" 2>/dev/null
    mv "$NC_SUB_FE" "$NC_SUB_FE.old" 2>/dev/null
    mv "$_src" "$NC_SUB_FE" 2>/dev/null || {
        nc_err "替换前端目录失败"
        mv "$NC_SUB_FE.old" "$NC_SUB_FE" 2>/dev/null
        rm -rf "$_dir"
        return 1
    }
    chmod -R a+rX "$NC_SUB_FE" 2>/dev/null
    rm -rf "$_dir" 2>/dev/null

    if [ -n "$_newver" ]; then
        printf '%s\n' "$_newver" >"$(nc_sub_frontend_version_file)" 2>/dev/null
    else
        _newver="unknown"
    fi
    nc_info "Sub-Store 前端已更新: ${_current:-未安装} -> $_newver"
    return 0
}

nc_sub_update() {
    local _fail _part _was_running
    _part=${1:-all}
    case "$_part" in
        all|backend|frontend|node) ;;
        *) nc_err "用法: sub update <all|backend|frontend|node>"; return 2 ;;
    esac

    _was_running=0
    nc_sub_running && _was_running=1
    if [ "$_was_running" = "1" ]; then
        nc_info "停止 Sub-Store 以更新组件..."
        nc_sub_stop >/dev/null 2>&1
    fi

    _fail=0
    case "$_part" in
        node)
            nc_node_update || _fail=1
            ;;
        backend)
            nc_sub_update_backend || _fail=1
            ;;
        frontend)
            nc_sub_update_frontend || _fail=1
            ;;
        all)
            # 首次使用时把 Node 一起装上；已有 Node 不自动重装，避免每次更新都拉 40MB
            if [ ! -x "$NC_NODE_BIN" ] && [ -z "$(nc_sub_node)" ]; then
                nc_node_update || _fail=1
            fi
            nc_sub_update_backend || _fail=1
            nc_sub_update_frontend || _fail=1
            ;;
    esac

    if [ "$_was_running" = "1" ]; then
        nc_info "重启 Sub-Store..."
        nc_sub_start || _fail=1
    fi

    [ "$_fail" = "0" ] && nc_info "Sub-Store 组件更新完成"
    return "$_fail"
}
