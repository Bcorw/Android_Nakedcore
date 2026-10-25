#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - sing-box / mihomo 内核管理
# ============================================================

nc_core_valid() {
    case "$1" in
        sing-box|mihomo) return 0 ;;
        *) return 1 ;;
    esac
}

nc_core_dir() {
    case "$1" in
        sing-box) printf '%s' "$NC_SB" ;;
        mihomo)   printf '%s' "$NC_MH" ;;
    esac
}

nc_core_bin() {
    case "$1" in
        sing-box) printf '%s' "$NC_SB_BIN" ;;
        mihomo)   printf '%s' "$NC_MH_BIN" ;;
    esac
}

nc_core_config() {
    case "$1" in
        sing-box) printf '%s' "$NC_SB_CONFIG" ;;
        mihomo)   printf '%s' "$NC_MH_CONFIG" ;;
    esac
}

nc_core_channel() {
    case "$1" in
        sing-box) printf '%s' "$NC_SB_CHANNEL" ;;
        mihomo)   printf '%s' "$NC_MH_CHANNEL" ;;
    esac
}

nc_core_pidfile() { printf '%s/%s.pid' "$NC_RUN" "$1"; }
nc_core_log()     { printf '%s/%s.log' "$NC_RUN" "$1"; }
nc_core_check_file() { printf '%s/%s.check' "$NC_RUN" "$1"; }
nc_core_started() { printf '%s/%s.started' "$NC_RUN" "$1"; }
nc_core_version_file() { printf '%s/%s.version' "$NC_BIN" "$1"; }
nc_core_old_bin() { printf '%s/%s.old' "$NC_BIN" "$1"; }
nc_core_old_version() { printf '%s/%s.version.old' "$NC_BIN" "$1"; }

nc_core_installed() {
    local _bin
    _bin=$(nc_core_bin "$1")
    [ -n "$_bin" ] && [ -x "$_bin" ]
}

# 读取内核版本：版本文件比二进制新时优先用文件（alpha 版本的 -v 输出不一定含标准版本号）
nc_core_version() {
    local _bin _core _v _vf
    _core=$1
    _bin=$(nc_core_bin "$_core")
    _vf=$(nc_core_version_file "$_core")
    if [ -f "$_vf" ] && { [ ! -x "$_bin" ] || [ ! "$_bin" -nt "$_vf" ]; }; then
        IFS= read -r _v <"$_vf" 2>/dev/null
        printf '%s' "${_v%\r}"
        return 0
    fi
    if [ -x "$_bin" ]; then
        if [ "$_core" = "sing-box" ]; then
            _v=$("$_bin" version 2>/dev/null | head -n 1 | awk '{print $3}' | tr -d '\r\n')
        else
            _v=$("$_bin" -v 2>/dev/null | head -n 1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1 | tr -d '\r\n')
        fi
        _v=${_v#v}
        [ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
    fi
    if [ -f "$_vf" ]; then
        IFS= read -r _v <"$_vf" 2>/dev/null
        printf '%s' "${_v%\r}"
    fi
}

nc_core_config_size() {
    local _cfg
    _cfg=$(nc_core_config "$1")
    [ -f "$_cfg" ] && nc_file_size "$_cfg" || echo 0
}

nc_core_config_state() {
    local _cfg _check _core _rest _st
    _core=$1
    _cfg=$(nc_core_config "$_core")
    _check=$(nc_core_check_file "$_core")
    [ -f "$_cfg" ] || { echo "none"; return 0; }
    [ -f "$_check" ] || { echo "unknown"; return 0; }
    # 配置比校验结果新：校验结果已失效
    if [ "$_cfg" -nt "$_check" ]; then
        echo "unknown"
        return 0
    fi
    _st=""
    read -r _st _rest <"$_check" 2>/dev/null
    case "$_st" in
        ok|fail) echo "$_st" ;;
        *) echo "unknown" ;;
    esac
}

nc_core_config_dirty() {
    local _cfg _core _marker
    _core=$1
    _cfg=$(nc_core_config "$_core")
    _marker=$(nc_core_started "$_core")
    nc_core_running "$_core" || return 1
    [ -f "$_cfg" ] && [ -f "$_marker" ] && [ "$_cfg" -nt "$_marker" ]
}

nc_core_running() {
    local _bin _core _pid _pidfile
    _core=$1
    _bin=$(nc_core_bin "$_core")
    _pidfile=$(nc_core_pidfile "$_core")
    [ -n "$_bin" ] || return 1

    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$_bin"; then
            return 0
        fi
    fi

    # 兜底：按进程名查找，并确认 cmdline 确实是本模块的二进制
    for _pid in $(nc_pids_by_name "$_core" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$_bin"; then
            echo "$_pid" >"$_pidfile" 2>/dev/null
            return 0
        fi
    done
    return 1
}

nc_core_pid() {
    local _bin _core _pid _pidfile
    _core=$1
    _pidfile=$(nc_core_pidfile "$_core")
    _bin=$(nc_core_bin "$_core")
    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$_bin"; then
            printf '%s' "$_pid"
            return 0
        fi
    fi
    for _pid in $(nc_pids_by_name "$_core" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$_bin"; then
            printf '%s' "$_pid"
            return 0
        fi
    done
    return 1
}

nc_core_write_check() {
    local _core _msg _state
    _core=$1
    _state=$2
    _msg=$3
    printf '%s %s %s\n' "$_state" "$(nc_now)" "$_msg" >"$(nc_core_check_file "$_core")" 2>/dev/null
}

# 校验配置，输出人类可读结果；返回 0/1
nc_core_check() {
    local _bin _cfg _core _dir _msg _out _rc _ver
    _core=$1
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }
    nc_core_installed "$_core" || {
        nc_core_write_check "$_core" fail "未安装内核"
        nc_err "未安装 $_core 内核"
        return 1
    }
    _bin=$(nc_core_bin "$_core")
    _dir=$(nc_core_dir "$_core")
    _cfg=$(nc_core_config "$_core")
    [ -f "$_cfg" ] || {
        nc_core_write_check "$_core" fail "找不到配置文件"
        nc_err "找不到配置文件: $_cfg"
        return 1
    }

    if [ "$_core" = "sing-box" ]; then
        _out=$("$_bin" check -D "$_dir" -c "$_cfg" 2>&1)
    else
        _out=$("$_bin" -t -d "$_dir" -f "$_cfg" 2>&1)
    fi
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        _ver=$(nc_core_version "$_core")
        nc_core_write_check "$_core" ok "v${_ver:-?}"
        nc_info "校验通过: $_core 配置合法"
        return 0
    else
        _msg=$(printf '%s' "$_out" | head -n 3 | tr '\n' ' ' | tr -d '\r')
        nc_core_write_check "$_core" fail "$_msg"
        nc_err "校验失败: $_msg"
        return 1
    fi
}

# 停止另一个内核，保证同一时间只有一个裸核在运行
nc_core_stop_others() {
    local _c _keep
    _keep=$1
    for _c in sing-box mihomo; do
        [ "$_c" = "$_keep" ] && continue
        if nc_core_running "$_c"; then
            nc_info "停止另一个内核: $_c"
            nc_core_stop_one "$_c" >/dev/null 2>&1
        fi
    done
}

nc_core_stop_one() {
    local _bin _core _pid _pidfile _stopped
    _core=$1
    _bin=$(nc_core_bin "$_core")
    _pidfile=$(nc_core_pidfile "$_core")
    _stopped=0

    if [ -f "$_pidfile" ]; then
        _pid=$(cat "$_pidfile" 2>/dev/null | tr -d ' \r\n')
        if nc_pid_matches "$_pid" "$_bin"; then
            nc_stop_pid "$_pid"
            _stopped=1
        fi
    fi

    for _pid in $(nc_pids_by_name "$_core" 2>/dev/null); do
        if nc_pid_matches "$_pid" "$_bin"; then
            nc_stop_pid "$_pid"
            _stopped=1
        fi
    done

    rm -f "$_pidfile" "$(nc_core_started "$_core")" 2>/dev/null
    command -v nc_hotspot_sync >/dev/null 2>&1 && nc_hotspot_sync
    if [ "$_stopped" = "1" ]; then
        nc_info "已停止 $_core"
    else
        nc_info "$_core 未在运行"
    fi
    return 0
}

nc_core_stop() {
    if [ -n "$1" ]; then
        nc_core_valid "$1" || { nc_err "未知内核: $1"; return 2; }
        nc_core_stop_one "$1"
    else
        nc_core_stop_one sing-box
        nc_core_stop_one mihomo
    fi
}

nc_core_start() {
    local _bin _cfg _core _dir _log _pid _pidfile _ver
    _core=$1
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }

    if nc_core_running "$_core"; then
        _pid=$(nc_core_pid "$_core")
        nc_info "$_core 已在内核运行 (PID: ${_pid:-?})"
        [ "$NC_ACTIVE_CORE" = "$_core" ] || {
            NC_ACTIVE_CORE="$_core"
            nc_save_settings
        }
        return 0
    fi

    nc_core_installed "$_core" || { nc_err "未安装 $_core 内核，请先在核心页更新"; return 1; }

    # 启动前严格校验，避免把系统带到无网络状态
    nc_core_check "$_core" || return 1

    nc_core_stop_others "$_core"

    _bin=$(nc_core_bin "$_core")
    _dir=$(nc_core_dir "$_core")
    _cfg=$(nc_core_config "$_core")
    _log=$(nc_core_log "$_core")
    _pidfile=$(nc_core_pidfile "$_core")

    if [ "$_core" = "sing-box" ]; then
        nc_launch "$_log" "$_pidfile" -900 "$_bin" "$_bin" run -D "$_dir" -c "$_cfg"
    else
        nc_launch "$_log" "$_pidfile" -900 "$_bin" "$_bin" -d "$_dir" -f "$_cfg"
    fi

    if [ $? -ne 0 ] || ! nc_core_running "$_core"; then
        nc_err "启动失败: $_core"
        nc_tail_log "$_log" 12
        return 1
    fi

    date '+%Y-%m-%d %H:%M:%S' >"$(nc_core_started "$_core")" 2>/dev/null
    NC_ACTIVE_CORE="$_core"
    nc_save_settings

    command -v nc_hotspot_sync >/dev/null 2>&1 && nc_hotspot_sync

    _pid=$(nc_core_pid "$_core")
    nc_info "启动成功: $_core (PID: ${_pid:-?})"
    _ver=$(nc_core_version "$_core")
    [ -n "$_ver" ] && nc_info "内核版本: $_ver"
    return 0
}

nc_core_restart() {
    local _core
    _core=$1
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }
    # 先校验再停：避免配置损坏时把正在运行的内核停掉
    nc_core_check "$_core" || return 1
    nc_core_stop_one "$_core" >/dev/null 2>&1
    nc_core_start "$_core"
}

nc_core_switch() {
    local _prev _target _was_running
    _target=$1
    nc_core_valid "$_target" || { nc_err "未知内核: $_target"; return 2; }
    _prev=$NC_ACTIVE_CORE

    nc_core_installed "$_target" || { nc_err "未安装 $_target 内核，无法切换"; return 1; }

    _was_running=0
    nc_core_running "$_prev" && _was_running=1

    # 没有内核在运行：切换只是修改激活设置，不要求目标已有配置
    if [ "$_was_running" = "0" ]; then
        if [ "$_target" = "$_prev" ]; then
            nc_info "当前已经是 $_target（未运行）"
            return 0
        fi
        NC_ACTIVE_CORE="$_target"
        nc_save_settings
        if [ -f "$(nc_core_config "$_target")" ]; then
            nc_info "已切换激活内核为: $_target（当前未运行，启动前会校验配置）"
        else
            nc_info "已切换激活内核为: $_target（当前未运行；尚未导入配置，导入后即可启动）"
        fi
        return 0
    fi

    # 当前已经有内核在跑：目标必须完整可用，避免把网络切断
    if [ "$_target" = "$_prev" ]; then
        nc_info "当前已经是 $_target（运行中）"
        return 0
    fi
    if [ ! -f "$(nc_core_config "$_target")" ]; then
        nc_err "$_target 缺少配置文件，已保留当前运行的 $_prev"
        return 1
    fi
    nc_core_check "$_target" || {
        nc_err "$_target 配置校验失败，已保留当前运行的 $_prev"
        return 1
    }

    nc_info "切换内核: $_prev -> $_target"
    nc_core_stop_one "$_prev" >/dev/null 2>&1
    NC_ACTIVE_CORE="$_target"
    nc_save_settings
    if ! nc_core_start "$_target"; then
        nc_warn "新内核启动失败，回退到 $_prev"
        NC_ACTIVE_CORE="$_prev"
        nc_save_settings
        nc_core_start "$_prev" >/dev/null 2>&1
        return 1
    fi
    return 0
}

# 删除内核：删除二进制/版本/回滚缓存与运行标记，保留配置和日志
nc_core_delete() {
    local _bin _c _core _next _old _oldvf _vf
    _core=$1
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }
    _bin=$(nc_core_bin "$_core")

    if nc_core_running "$_core"; then
        nc_info "停止正在运行的 $_core..."
        nc_core_stop_one "$_core" >/dev/null 2>&1
    fi

    _vf=$(nc_core_version_file "$_core")
    _old=$(nc_core_old_bin "$_core")
    _oldvf=$(nc_core_old_version "$_core")
    rm -f "$_bin" "$_vf" "$_old" "$_oldvf" 2>/dev/null
    rm -f "$(nc_core_pidfile "$_core")" "$(nc_core_started "$_core")" "$(nc_core_check_file "$_core")" 2>/dev/null

    if [ "$NC_ACTIVE_CORE" = "$_core" ]; then
        _next=""
        for _c in sing-box mihomo; do
            [ "$_c" = "$_core" ] && continue
            [ -x "$(nc_core_bin "$_c")" ] && { _next="$_c"; break; }
        done
        if [ -n "$_next" ]; then
            NC_ACTIVE_CORE="$_next"
            nc_info "激活内核已切换为: $_next（未启动）"
        else
            NC_ACTIVE_CORE="sing-box"
            NC_AUTO_START="false"
            nc_warn "没有其他可用内核，已关闭内核自启"
        fi
        nc_save_settings
    fi

    nc_info "已删除 $_core 内核（配置文件与日志保留）"
    return 0
}

# ---------- 版本查询（不依赖 GitHub API，避免限流） ----------
nc_curl_effective() {
    local _eff _proxy_url _rc _url
    _url=$1
    [ -n "$NC_CURL" ] || return 1
    _eff=$("$NC_CURL" -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 20 "$_url" 2>/dev/null)
    _rc=$?
    [ "$_rc" -eq 0 ] || _eff=""
    # HEAD 被代理/防火墙拦截时返回原地址，不能当作重定向成功
    printf '%s' "$_eff" | grep -q '/tag/' || _eff=""
    _proxy_url=$(nc_proxy_url "$_url")
    if [ -z "$_eff" ] && [ "$_proxy_url" != "$_url" ]; then
        _eff=$("$NC_CURL" -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 20 "$_proxy_url" 2>/dev/null)
        _rc=$?
        [ "$_rc" -eq 0 ] || _eff=""
        printf '%s' "$_eff" | grep -q '/tag/' || _eff=""
    fi
    [ -n "$_eff" ] || return 1
    printf '%s' "$_eff"
}

nc_extract_tag() {
    printf '%s' "$1" | sed -n 's#.*/tag/\([^/?#]*\).*#\1#p' | head -n 1
}

nc_singbox_latest() {
    local _channel _file _tag
    _channel=${1:-stable}

    # 1) Atom feed：文件小、不需要 API、不受 560KB release HTML 影响
    _tag=$(nc_github_atom_tag SagerNet/sing-box "$_channel" 2>/dev/null)
    if [ -n "$_tag" ]; then
        printf '%s' "${_tag#v}"
        return 0
    fi

    # 2) GitHub API（部分网络会被 403 限流，文件方式解析）
    _file="$NC_TMP/sb-api.$$.json"
    if [ "$_channel" = "alpha" ]; then
        if nc_fetch_file "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20" "$_file" 20; then
            _tag=$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*alpha[^"]*"' "$_file" 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
        fi
    else
        if nc_fetch_file "https://api.github.com/repos/SagerNet/sing-box/releases/latest" "$_file" 20; then
            _tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_file" 2>/dev/null | head -n 1)
        fi
    fi
    rm -f "$_file" 2>/dev/null
    if [ -n "$_tag" ]; then
        printf '%s' "${_tag#v}"
        return 0
    fi

    # 3) release HTML：写到文件再 grep，绝不把 560KB 塞进 printf argv
    _file="$NC_TMP/sb-html.$$.html"
    if nc_fetch_file "https://github.com/SagerNet/sing-box/releases" "$_file" 30; then
        if [ "$_channel" = "alpha" ]; then
            _tag=$(grep -oE '/SagerNet/sing-box/releases/tag/v[0-9][^"/]*alpha[^"/]*' "$_file" 2>/dev/null | head -n 1 | sed 's#.*/tag/##')
        else
            _tag=$(grep -oE '/SagerNet/sing-box/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+"' "$_file" 2>/dev/null | head -n 1 | sed 's#.*/tag/##; s#"$##')
        fi
    fi
    rm -f "$_file" 2>/dev/null

    [ -n "$_tag" ] || return 1
    printf '%s' "${_tag#v}"
}

nc_mihomo_tag() {
    local _channel _file _tag _url
    _channel=${1:-stable}
    if [ "$_channel" = "alpha" ]; then
        _tag=$(nc_fetch_text "https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt" 20) || _tag=""
        if [ -z "$_tag" ]; then
            # API 兜底：从 Prerelease-Alpha release 的资产名提取 alpha-xxxx
            _file="$NC_TMP/mh-alpha.$$.json"
            if nc_fetch_file "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha" "$_file" 20; then
                _url=$(grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*mihomo-android-[^"]*-alpha-[^"]*\.gz"' "$_file" 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
                if [ -n "$_url" ]; then
                    _tag=$(printf '%s' "$_url" | sed -n 's/.*\(alpha-[A-Za-z0-9]*\)\.gz$/\1/p')
                fi
            fi
            rm -f "$_file" 2>/dev/null
        fi
    else
        _tag=$(nc_fetch_text "https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt" 20) || _tag=""
        if [ -z "$_tag" ]; then
            _file="$NC_TMP/mh-latest.$$.json"
            if nc_fetch_file "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" "$_file" 20; then
                _tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_file" 2>/dev/null | head -n 1)
            fi
            rm -f "$_file" 2>/dev/null
        fi
    fi
    _tag=$(printf '%s' "$_tag" | tr -d '\r\n ')
    [ -n "$_tag" ] || return 1
    printf '%s' "$_tag"
}

nc_mihomo_latest() {
    local _tag
    _tag=$(nc_mihomo_tag "${1:-stable}") || return 1
    printf '%s' "${_tag#v}"
}


nc_core_latest() {
    case "$1" in
        sing-box) nc_singbox_latest "${2:-stable}" ;;
        mihomo)   nc_mihomo_latest "${2:-stable}" ;;
        *) return 1 ;;
    esac
}

# 根据 channel 生成下载 URL
nc_core_download_url() {
    local _channel _core _tag _ver
    _core=$1
    _channel=$2
    if [ "$_core" = "sing-box" ]; then
        _ver=$(nc_singbox_latest "$_channel") || return 1
        printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-android-%s.tar.gz' \
            "$_ver" "$_ver" "$NC_SB_ARCH"
    else
        _tag=$(nc_mihomo_tag "$_channel") || return 1
        if [ "$_channel" = "alpha" ]; then
            printf 'https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-android-%s-%s.gz' \
                "$NC_MH_ARCH" "$_tag"
        else
            printf 'https://github.com/MetaCubeX/mihomo/releases/download/%s/mihomo-android-%s-%s.gz' \
                "$_tag" "$NC_MH_ARCH" "$_tag"
        fi
    fi
}

# ---------- 更新 ----------
nc_core_update() {
    local _archive _bin _channel _core _current _found _latest _newver _old _oldvf _rawver _tmpbin _url _vf _was_running _work
    _core=$1
    _channel=${2:-stable}
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }
    case "$_channel" in stable|alpha) ;; *) nc_err "未知通道: $_channel"; return 2 ;; esac

    _latest=$(nc_core_latest "$_core" "$_channel")
    if [ -z "$_latest" ]; then
        nc_err "无法获取 $_core 最新版本（检查网络或 GitHub 加速地址）"
        return 1
    fi
    _current=$(nc_core_version "$_core")
    nc_info "当前版本: ${_current:-未安装}"
    nc_info "最新版本: $_latest ($_channel)"

    if [ "$_current" = "$_latest" ] && nc_core_installed "$_core"; then
        nc_info "$_core 已是最新版本，无需更新"
        return 0
    fi

    _url=$(nc_core_download_url "$_core" "$_channel") || {
        nc_err "无法生成下载地址"
        return 1
    }

    _work="$NC_TMP/update-$_core-$$"
    rm -rf "$_work" 2>/dev/null
    mkdir -p "$_work" 2>/dev/null
    _archive="$_work/archive"
    _tmpbin="$_work/$_core"

    if [ "$_core" = "sing-box" ]; then
        nc_download "$_url" "$_archive" || { rm -rf "$_work"; return 1; }
        nc_tar_xzf "$_archive" "$_work" || { nc_err "解压失败"; rm -rf "$_work"; return 1; }
        _found=$(nc_find_file "$_work" sing-box)
        if [ -z "$_found" ]; then
            nc_err "压缩包中未找到 sing-box 二进制"
            rm -rf "$_work"
            return 1
        fi
        cp -f "$_found" "$_tmpbin" 2>/dev/null
    else
        nc_download "$_url" "$_work/mihomo.gz" || { rm -rf "$_work"; return 1; }
        nc_gunzip "$_work/mihomo.gz" "$_tmpbin" || { nc_err "解压失败"; rm -rf "$_work"; return 1; }
    fi

    [ -s "$_tmpbin" ] || { nc_err "下载的二进制为空"; rm -rf "$_work"; return 1; }
    chmod 755 "$_tmpbin" 2>/dev/null

    # 验证下载的二进制能正常执行
    if [ "$_core" = "sing-box" ]; then
        _rawver=$("$_tmpbin" version 2>/dev/null | head -n 1)
        _newver=$(printf '%s' "$_rawver" | awk '{print $3}' | tr -d '\r\n')
    else
        _rawver=$("$_tmpbin" -v 2>/dev/null | head -n 1)
        _newver=$(printf '%s' "$_rawver" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1 | tr -d '\r\n')
    fi
    _newver=${_newver#v}
    if [ -z "$_rawver" ]; then
        nc_err "下载的 $_core 无法执行（架构不匹配或文件损坏）"
        rm -rf "$_work"
        return 1
    fi
    # alpha 版本的 -v 输出可能没有标准版本号，回退到远端标签
    [ -n "$_newver" ] || _newver="$_latest"
    nc_info "下载版本: $_newver"

    _bin=$(nc_core_bin "$_core")
    _vf=$(nc_core_version_file "$_core")
    _old=$(nc_core_old_bin "$_core")
    _oldvf=$(nc_core_old_version "$_core")

    _was_running=0
    nc_core_running "$_core" && _was_running=1
    if [ "$_was_running" = "1" ]; then
        nc_info "停止 $_core 以替换内核..."
        nc_core_stop_one "$_core" >/dev/null 2>&1
    fi

    cp -f "$_bin" "$_old" 2>/dev/null
    [ -f "$_vf" ] && cp -f "$_vf" "$_oldvf" 2>/dev/null
    cp -f "$_tmpbin" "$_bin" 2>/dev/null || { nc_err "写入内核失败"; rm -rf "$_work"; return 1; }
    chmod 755 "$_bin" 2>/dev/null
    printf '%s\n' "$_newver" >"$_vf" 2>/dev/null
    rm -rf "$_work" 2>/dev/null

    nc_info "$_core 已更新到 $_newver"

    if [ "$_was_running" = "1" ]; then
        if ! nc_core_start "$_core"; then
            nc_err "新版本启动失败，自动回滚到旧版本"
            nc_core_stop_one "$_core" >/dev/null 2>&1
            cp -f "$_old" "$_bin" 2>/dev/null
            [ -f "$_oldvf" ] && cp -f "$_oldvf" "$_vf" 2>/dev/null
            chmod 755 "$_bin" 2>/dev/null
            nc_core_start "$_core" >/dev/null 2>&1
            nc_err "已回滚，请检查配置与新版本兼容性"
            return 1
        fi
    fi
    return 0
}

nc_core_rollback() {
    local _bin _core _old _oldvf _vf _was_running
    _core=$1
    nc_core_valid "$_core" || { nc_err "未知内核: $_core"; return 2; }
    _bin=$(nc_core_bin "$_core")
    _old=$(nc_core_old_bin "$_core")
    _vf=$(nc_core_version_file "$_core")
    _oldvf=$(nc_core_old_version "$_core")
    [ -x "$_old" ] || { nc_err "没有可回滚的旧版本"; return 1; }

    _was_running=0
    nc_core_running "$_core" && _was_running=1
    [ "$_was_running" = "1" ] && nc_core_stop_one "$_core" >/dev/null 2>&1

    cp -f "$_bin" "$_bin.broken" 2>/dev/null
    cp -f "$_old" "$_bin" 2>/dev/null
    [ -f "$_oldvf" ] && cp -f "$_oldvf" "$_vf" 2>/dev/null
    chmod 755 "$_bin" 2>/dev/null
    rm -f "$_old" "$_oldvf" 2>/dev/null
    nc_info "已回滚 $_core 到旧版本"

    if [ "$_was_running" = "1" ]; then
        nc_core_start "$_core" || return 1
    fi
    return 0
}
