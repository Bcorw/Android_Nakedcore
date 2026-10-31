#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 连通性 / 服务状态
#
# 设计要点（V1.2.0 重构）：
#  1. 传输层与业务规则分离：curl 优先，busybox wget 兜底，
#     没有 curl 的设备也能出结果，而不是静默「检测失败」。
#  2. 每条探测只做一次「结论写入」：多请求服务（ChatGPT / Disney /
#     Netflix）的辅助请求失败，不会把已经成立的结果改成超时。
#  3. 结果按服务单独落盘（run/connectivity/<id>.json），单项刷新
#     也会持久化；聚合读取时逐文件校验，坏文件不会污染整份结果。
#  4. 失败要能解释：区分 DNS / 连接 / 超时 / TLS / 证书 / 限流，
#     在 hint 字段给出人话诊断，UI 不用再展示裸 curl 报错。
#  5. 地区码统一为 ISO-3166 alpha-2：三字码（CHN/SGP）先归一，
#     无法识别的结果直接丢弃，不再出现 "API"/"WWW" 这种假地区。
# ============================================================

NC_CONN_DIR="$NC_RUN/connectivity"
NC_CONN_TIMEOUT="${NC_CONN_TIMEOUT:-9}"
NC_CONN_CONNECT_TIMEOUT="${NC_CONN_CONNECT_TIMEOUT:-6}"
NC_CONN_JOBS="${NC_CONN_JOBS:-5}"
NC_CONN_RETRY="${NC_CONN_RETRY:-1}"
NC_CONN_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
NC_DISNEY_AUTH="Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"

# ISO-3166 alpha-3 -> alpha-2（只覆盖探测可能遇到的地区）
NC_CONN_ISO3="
CHN=CN RUS=RU BLR=BY CUB=CU IRN=IR PRK=KP SYR=SY HKG=HK MAC=MO TWN=TW
USA=US GBR=GB JPN=JP KOR=KR SGP=SG MYS=MY THA=TH IDN=ID VNM=VN PHL=PH
IND=IN PAK=PK BGD=BD LKA=LK NPL=NP KAZ=KZ ARE=AE SAU=SA ISR=IL TUR=TR
DEU=DE FRA=FR NLD=NL ESP=ES ITA=IT CHE=CH AUT=AT SWE=SE NOR=NO DNK=DK
FIN=FI POL=PL CZE=CZ HUN=HU ROU=RO UKR=UA IRL=IE PRT=PT GRC=GR BEL=BE
LUX=LU CAN=CA MEX=MX BRA=BR ARG=AR CHL=CL COL=CO PER=PE AUS=AU NZL=NZ
ZAF=ZA EGY=EG NGA=NG KEN=KE MAR=MA
"

# ---------- 服务清单 ----------
# 这些状态字符串与 FlClash 的 ServiceProbeStatus 对齐
nc_conn_ids() {
    printf '%s\n' \
        google github youtube chatgpt claude gemini \
        netflix disney-plus prime-video spotify tiktok discord bilibili
}

# id|name|category|url|abbr|color
nc_conn_meta() {
    case "$1" in
        google)       printf 'Google|dev|https://www.google.com/generate_204|G|#4285f4' ;;
        github)       printf 'GitHub|dev|https://github.com/|GH|#24292f' ;;
        youtube)      printf 'YouTube|stream|https://www.youtube.com/premium?hl=en|YT|#ff0033' ;;
        chatgpt)      printf 'ChatGPT|ai|https://chat.openai.com/cdn-cgi/trace|C|#10a37f' ;;
        claude)       printf 'Claude|ai|https://claude.ai/cdn-cgi/trace|C|#d97757' ;;
        gemini)       printf 'Gemini|ai|https://gemini.google.com|G|#4285f4' ;;
        netflix)      printf 'Netflix|stream|https://www.netflix.com/title/81280792|N|#e50914' ;;
        disney-plus)  printf 'Disney+|stream|https://www.disneyplus.com|D|#113ccf' ;;
        prime-video)  printf 'Prime Video|stream|https://www.primevideo.com|P|#00a8e1' ;;
        spotify)      printf 'Spotify|stream|https://open.spotify.com|S|#1db954' ;;
        tiktok)       printf 'TikTok|stream|https://www.tiktok.com/|TT|#111111' ;;
        discord)      printf 'Discord|community|https://discord.com|D|#5865f2' ;;
        bilibili)     printf '哔哩哔哩|cn|https://www.bilibili.com|B|#00aeec' ;;
        *) return 1 ;;
    esac
}

nc_conn_valid() { nc_conn_meta "$1" >/dev/null 2>&1; }

nc_conn_label() {
    case "$1" in
        available) printf '可用' ;;
        restricted) printf '访问受限' ;;
        disallowed-isp) printf '不允许的 ISP' ;;
        blocked) printf '已被封禁' ;;
        unsupported-region) printf '地区不支持' ;;
        originals-only) printf '仅限自制内容' ;;
        coming-soon) printf '即将上线' ;;
        unavailable) printf '不可用' ;;
        timeout) printf '超时' ;;
        *) printf '检测失败' ;;
    esac
}

nc_conn_status_from_code() {
    case "$1" in
        2??) printf 'available' ;;
        401|403|451) printf 'restricted' ;;
        429) printf 'restricted' ;;
        3??) printf 'unavailable' ;;
        5??) printf 'unavailable' ;;
        *) printf 'unavailable' ;;
    esac
}

# ---------- 地区码 ----------
# 接受 2 字码或已知 3 字码，其余一律返回空（避免 API / WWW 这类假地区）
nc_conn_region() {
    local _p _r
    _r=$(printf '%s' "$1" | tr -d ' \r\n\t' | tr '[:lower:]' '[:upper:]')
    # 常见别名统一到 ISO 官方二字码，避免同一地区出现 GB / UK 两种写法
    case "$_r" in
        UK) _r=GB ;;
    esac
    case "$_r" in
        [A-Z][A-Z]) printf '%s' "$_r"; return 0 ;;
    esac
    for _p in $NC_CONN_ISO3; do
        [ "${_p%%=*}" = "$_r" ] && { printf '%s' "${_p#*=}"; return 0; }
    done
    return 0
}

nc_conn_region_in() {
    local _needle _word
    _needle=$1
    shift
    # shellcheck disable=SC2048
    for _word in $*; do
        [ "$_needle" = "$_word" ] && return 0
    done
    return 1
}

# ---------- HTTP 传输层 ----------
nc_http_client() {
    if [ -n "${NC_CONN_CLIENT:-}" ]; then
        printf '%s' "$NC_CONN_CLIENT"
        return 0
    fi
    if [ -n "${NC_CURL_OVERRIDE:-}" ]; then
        NC_CURL="$NC_CURL_OVERRIDE"
    fi
    if [ -n "$NC_CURL" ] && [ -x "$NC_CURL" ]; then
        NC_CONN_CLIENT=curl
    elif [ -n "$NC_BUSYBOX" ] && "$NC_BUSYBOX" --list 2>/dev/null | grep -qx wget; then
        NC_CONN_CLIENT=busybox
    elif command -v wget >/dev/null 2>&1; then
        NC_CONN_CLIENT=wget
    else
        NC_CONN_CLIENT=none
    fi
    printf '%s' "$NC_CONN_CLIENT"
}

# 统一的状态：_h_code / _h_ms / _h_eff / _h_err / _h_kind
nc_http_reset() {
    _h_code=0
    _h_ms=0
    _h_eff=$1
    _h_err=""
    _h_kind=""
}

nc_http_curl() {
    local _auth _ctype _mode _out _payload _url _meta _rc _time
    _mode=$1; _url=$2; _out=$3
    shift 3
    # POST 的 ctype / payload / auth 必须转成 curl 参数，
    # 直接透传会被 curl 当成额外的 URL
    if [ "$_mode" = "POST" ]; then
        _ctype=${1:-}; _payload=${2:-}; _auth=${3:-}
        set --
        [ -n "$_ctype" ] && set -- "$@" -H "content-type: $_ctype"
        set -- "$@" --data-binary "$_payload"
        [ -n "$_auth" ] && set -- "$@" -H "authorization: $_auth"
    fi
    _meta=$("$NC_CURL" -L -sS --compressed -A "$NC_CONN_UA" \
        --connect-timeout "$NC_CONN_CONNECT_TIMEOUT" --max-time "$NC_CONN_TIMEOUT" \
        "$@" -o "$_out" -w '%{http_code} %{time_total} %{url_effective}' "$_url" 2>"$_c_err")
    _rc=$?
    set -- $_meta
    case "${1:-0}" in *[!0-9]*|"") _h_code=0 ;; *) _h_code=$1 ;; esac
    _time=${2:-0}
    case "$_time" in *[!0-9.]*|"") _time=0 ;; esac
    _h_ms=$(awk -v t="$_time" 'BEGIN { printf "%d", t * 1000 + 0.5 }' 2>/dev/null)
    case "$_h_ms" in *[!0-9]*|"") _h_ms=0 ;; esac
    [ -n "${3:-}" ] && _h_eff=$3

    [ "$_rc" -eq 0 ] && [ "$_h_code" -gt 0 ] && return 0

    _h_err=$(head -n 1 "$_c_err" 2>/dev/null | tr -d '\r' | cut -c1-200)
    case "$_rc" in
        0) _h_kind=fail ;;
        6) _h_kind=resolve ;;
        7) _h_kind=connect ;;
        28) case "$_h_err" in
                *esolv*) _h_kind=resolve ;;
                *"timed out"*|*timeout*) _h_kind=timeout ;;
                *onnect*) _h_kind=connect ;;
                *) _h_kind=timeout ;;
            esac ;;
        35|53|54|58|59|77|80|83|90|91) _h_kind=tls ;;
        60) _h_kind=cert ;;
        56) _h_kind=reset ;;
        18) _h_kind=partial ;;
        23) _h_kind=write ;;
        127) _h_kind=noclient ;;
        *) _h_kind=fail ;;
    esac
    return 1
}

nc_http_wget() {
    local _bin _mode _url _out _rc _ctype _payload _auth _hf
    _mode=$1; _url=$2; _out=$3
    shift 3
    _ctype=${1:-}; _payload=${2:-}; _auth=${3:-}
    _hf="$_c_err"

    if [ "$NC_CONN_CLIENT" = "busybox" ] && [ -n "$NC_BUSYBOX" ] \
        && "$NC_BUSYBOX" --list 2>/dev/null | grep -qx wget; then
        set -- "$NC_BUSYBOX" wget
    else
        _bin=$(command -v wget 2>/dev/null)
        [ -n "$_bin" ] || { _h_kind=noclient; _h_err="缺少 wget"; return 1; }
        set -- "$_bin"
    fi
    set -- "$@" -q -S -O "$_out" --timeout="$NC_CONN_TIMEOUT"
    if [ "$_mode" = "POST" ]; then
        set -- "$@" --header="Content-Type: $_ctype"
        [ -n "$_auth" ] && set -- "$@" --header="Authorization: $_auth"
        set -- "$@" --post-data="$_payload"
    fi
    "$@" "$_url" 2>"$_hf"
    _rc=$?

    _h_code=$(sed -n 's/^[[:space:]]*HTTP\/[0-9.]*[[:space:]][[:space:]]*\([0-9][0-9][0-9]\).*/\1/p' "$_hf" 2>/dev/null | tail -n 1)
    case "$_h_code" in *[!0-9]*|"") _h_code=0 ;; esac
    [ "$_h_code" -gt 0 ] && return 0

    _h_err=$(grep -v -e '^[[:space:]]*HTTP/' -e '^Connecting to' -e '^[[:space:]]*$' "$_hf" 2>/dev/null \
        | head -n 1 | tr -d '\r' | cut -c1-200)
    case "$_h_err" in
        *"unable to resolve"*|*"bad address"*) _h_kind=resolve ;;
        *"Connection timed out"*|*"download timed out"*|*"timed out"*) _h_kind=timeout ;;
        *"Connection refused"*|*"Network unreachable"*) _h_kind=connect ;;
        *"bad TLS record"*|*certificate*|*"TLS"*|*"SSL"*) _h_kind=tls ;;
        *) _h_kind=fail ;;
    esac
    # busybox wget 不做证书校验，遇到强制校验的站点只能明确告知
    if grep -q "certificate validation not implemented" "$_hf" 2>/dev/null; then
        _h_kind=notls
    fi
    return 1
}

# nc_http_do GET|POST <url> <out> [ctype payload auth]
nc_http_do() {
    local _client
    _client=$(nc_http_client)
    # 必须在当前 shell 里落地，子函数要靠它选择 busybox / 独立 wget
    NC_CONN_CLIENT=$_client
    _h_eff=""
    nc_http_reset "$2"
    case "$_client" in
        curl) nc_http_curl "$@" ;;
        busybox|wget) nc_http_wget "$@" ;;
        *) _h_kind=noclient; _h_err="缺少 curl / wget"; return 1 ;;
    esac
}

nc_http_hint() {
    case "$_h_kind" in
        resolve)  printf 'DNS 解析失败' ;;
        connect)  printf '连接失败，目标不可达' ;;
        timeout)  printf '连接超时' ;;
        tls)      printf 'TLS 握手失败' ;;
        cert)     printf '证书域名不匹配（疑似 DNS 污染或被拦截）' ;;
        reset)    printf '连接被重置' ;;
        partial)  printf '响应不完整' ;;
        write)    printf '写入临时文件失败' ;;
        noclient) printf '缺少 curl / wget，无法探测' ;;
        notls)    printf '当前 wget 不支持证书校验，无法探测该服务（建议安装 curl）' ;;
        *)        printf '请求失败' ;;
    esac
}

# 失败可重试：TLS/证书/重置这类握手阶段的瞬时错误值得重试一次；
# 解析/连接超时重试只会让整轮测试变慢，不重试。
nc_http_fetch() {
    nc_http_do "$@"
    [ "$_h_code" -gt 0 ] && return 0
    case "$_h_kind" in
        tls|cert|reset|fail|partial) ;;
        *) return 1 ;;
    esac
    [ "$NC_CONN_RETRY" -gt 0 ] || return 1
    nc_http_do "$@"
}

nc_body_has()   { grep -a -qi -F -- "$1" "$_c_body" 2>/dev/null; }
nc_body_first() { grep -a -oE -- "$1" "$_c_body" 2>/dev/null | head -n 1; }

# 读取跳转 Location（不跟随），用于 Netflix 地区判断
nc_http_location() {
    local _url
    _url=$1
    _c_location=""
    [ "$(nc_http_client)" = "curl" ] || return 0
    "$NC_CURL" -sS -o /dev/null -D "$_c_hdr" \
        --connect-timeout "$NC_CONN_CONNECT_TIMEOUT" --max-time "$NC_CONN_TIMEOUT" \
        -A "$NC_CONN_UA" "$_url" 2>/dev/null
    _c_location=$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$_c_hdr" 2>/dev/null | tr -d '\r' | head -n 1)
}

# ---------- 结果收集 ----------
nc_conn_reset() {
    _c_status=""
    _c_region=""
    _c_hint=""
    _c_error=""
    _c_http=0
    _c_delay=0
    _c_location=""
    _c_dir="$NC_TMP/conn.$$.$1"
    rm -rf "$_c_dir" 2>/dev/null
    mkdir -p "$_c_dir" 2>/dev/null
    _c_body="$_c_dir/body"
    _c_err="$_c_dir/err"
    _c_hdr="$_c_dir/hdr"
    : >"$_c_body" 2>/dev/null
}

nc_conn_cleanup() { rm -rf "$_c_dir" 2>/dev/null; }

# 记录结论：第一个成立的结论生效，后续辅助请求不再覆盖
nc_conn_done() {
    [ -n "$_c_status" ] && return 0
    _c_status=${1:-failed}
    [ -n "${2:-}" ] && _c_region=$2
    [ -n "${3:-}" ] && _c_hint=$3
    return 0
}

# 记录首个成功请求的 HTTP 码与耗时
nc_conn_mark() {
    [ "$_c_http" = "0" ] && _c_http=$_h_code
    [ "$_c_delay" = "0" ] && _c_delay=$_h_ms
}

nc_conn_fail() {
    _c_error=${_h_err:-}
    # 失败也记录耗时：用户需要看到「卡了 6 秒」而不是 0ms
    nc_conn_mark
    nc_conn_done "${1:-failed}" "" "${2:-$(nc_http_hint)}"
}

nc_conn_store() {
    local _file _json _tmp
    _file="$NC_CONN_DIR/$1.json"
    _json=$2
    mkdir -p "$NC_CONN_DIR" 2>/dev/null
    case "$_json" in
        "{"*"}") ;;
        *) return 1 ;;
    esac
    _tmp="$NC_CONN_DIR/.$1.$$"
    printf '%s\n' "$_json" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$_file" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    return 0
}

# ---------- 服务规则 ----------
nc_check_reachable() {
    nc_http_fetch GET "$1" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    case "$_h_code" in
        200|204) nc_conn_done available ;;
        401|403|429|451) nc_conn_done restricted "" "HTTP $_h_code" ;;
        *) nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "" "HTTP $_h_code" ;;
    esac
}

nc_check_claude() {
    local _reg
    nc_http_fetch GET "https://claude.ai/cdn-cgi/trace" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(sed -n 's/^loc=//p' "$_c_body" 2>/dev/null | head -n 1)")
    [ -n "$_reg" ] || { nc_conn_done failed "" "trace 中缺少地区字段"; return 0; }
    if nc_conn_region_in "$_reg" "AF BY CN CU HK IR KP MO RU SY"; then
        nc_conn_done unsupported-region "$_reg" "出口地区 $_reg 不在服务范围"
        return 0
    fi
    nc_conn_done available "$_reg"
}

nc_check_chatgpt() {
    local _reg _status _hint
    # 1) Cloudflare trace：出口地区
    nc_http_fetch GET "https://chat.openai.com/cdn-cgi/trace" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(sed -n 's/^loc=//p' "$_c_body" 2>/dev/null | head -n 1)")
    if [ -n "$_reg" ] && nc_conn_region_in "$_reg" "CN HK RU IR KP SY CU BY"; then
        nc_conn_done unsupported-region "$_reg" "出口地区 $_reg 不在服务范围"
        return 0
    fi

    # 2) 合规接口：明确的不支持国家
    nc_http_fetch GET "https://api.openai.com/compliance/cookie_requirements" "$_c_body"
    if [ "$_h_code" -gt 0 ] && nc_body_has "unsupported_country"; then
        nc_conn_done unsupported-region "$_reg"
        return 0
    fi

    # 3) 页面判定：这是「能不能用」的权威来源
    nc_http_fetch GET "https://ios.chat.openai.com/" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        # 辅助请求失败不回滚已确认的地区信息
        nc_conn_done available "$_reg"
        _c_hint="页面校验失败：$(nc_http_hint)"
        return 0
    fi
    _status=""
    _hint=""
    if nc_body_has "you may be connected to a disallowed isp"; then
        _status=disallowed-isp
        _hint="当前出口 IP 被 OpenAI 标记为不允许的 ISP"
    elif nc_body_has "sorry, you have been blocked"; then
        _status=blocked
        _hint="Cloudflare 拦截页"
    else
        _status=available
    fi
    nc_conn_done "$_status" "$_reg" "$_hint"
}

nc_check_gemini() {
    local _raw _reg
    nc_http_fetch GET "https://gemini.google.com" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _raw=$(nc_body_first ',2,1,200,"[A-Z][A-Z][A-Z]' | sed 's/.*"//')
    if [ -z "$_raw" ]; then
        case "$_h_code" in
            2??) nc_conn_done failed "" "页面结构变化，未找到地区标记" ;;
            *) nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "" "HTTP $_h_code" ;;
        esac
        return 0
    fi
    _reg=$(nc_conn_region "$_raw")
    # 限制列表是二字码，比对前先归一（CHN -> CN）
    if nc_conn_region_in "$_reg" "CN RU BY CU IR KP SY HK MO"; then
        nc_conn_done unsupported-region "$_reg" "地区标记 $_raw"
        return 0
    fi
    nc_conn_done available "$_reg"
}

nc_check_youtube() {
    local _reg
    nc_http_fetch GET "https://www.youtube.com/premium?hl=en" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_body_first '"GL"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    [ -n "$_reg" ] || _reg=$(nc_body_first '"countryCode"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    [ -n "$_reg" ] || _reg=$(nc_body_first '"country_code"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    _reg=$(nc_conn_region "$_reg")

    if nc_body_has "youtube premium is not available in your country" || \
       nc_body_has "premium is not available in your country" || \
       nc_body_has "premium is not available in your region"; then
        nc_conn_done unsupported-region "$_reg" "Premium 在该地区未上线"
        return 0
    fi
    if [ "$_h_code" -ge 200 ] && [ "$_h_code" -lt 300 ]; then
        nc_conn_done available "$_reg"
        return 0
    fi
    nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "$_reg" "HTTP $_h_code"
}

nc_check_spotify() {
    local _reg
    nc_http_fetch GET "https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(nc_body_first '"countryCode"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')")
    # 接口会 302 到 https://www.spotify.com/<cc>/api/...，body 可能为空
    [ -n "$_reg" ] || _reg=$(nc_conn_region "$(printf '%s' "$_h_eff" | sed -n 's#^[A-Za-z]*://[^/]*/\([A-Za-z][A-Za-z]\)/.*#\1#p')")
    case "$_h_code" in
        403|451) nc_conn_done unsupported-region "$_reg" "HTTP $_h_code" ; return 0 ;;
    esac
    if nc_body_has "not available in your country"; then
        nc_conn_done unsupported-region "$_reg" "页面提示地区不可用"
        return 0
    fi
    case "$_h_code" in
        2??) nc_conn_done available "$_reg" ;;
        *) nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "$_reg" "HTTP $_h_code" ;;
    esac
}

nc_check_tiktok() {
    local _reg
    nc_http_fetch GET "https://www.tiktok.com/" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(nc_body_first '"webapp\.app-context"[^}]*"region"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')")
    case "$_h_code" in
        403|451) nc_conn_done unsupported-region "$_reg" "HTTP $_h_code" ; return 0 ;;
    esac
    if nc_body_has "access denied" || nc_body_has "not available in your region" || nc_body_has "tiktok is not available"; then
        nc_conn_done unsupported-region "$_reg" "页面提示地区不可用"
        return 0
    fi
    case "$_h_code" in
        2??) nc_conn_done available "$_reg" ;;
        *) nc_conn_done failed "" "HTTP $_h_code" ;;
    esac
}

nc_check_bilibili() {
    local _code
    nc_http_fetch GET "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _code=$(nc_body_first '"code"[[:space:]]*:[[:space:]]*-?[0-9]+' | sed 's/.*"code"[[:space:]]*:[[:space:]]*//; s/[^0-9-].*//')
    case "$_code" in
        0) nc_conn_done available CN ;;
        -10403)
            nc_http_fetch GET "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi" "$_c_body"
            _code=$(nc_body_first '"code"[[:space:]]*:[[:space:]]*-?[0-9]+' | sed 's/.*"code"[[:space:]]*:[[:space:]]*//; s/[^0-9-].*//')
            if [ "$_code" = "0" ]; then
                nc_conn_done available CN
            else
                nc_conn_done unsupported-region CN "番剧接口返回 $_code"
            fi
            ;;
        "") nc_conn_done failed "" "接口返回结构异常" ;;
        *) nc_conn_done failed CN "接口返回 code=$_code" ;;
    esac
}

nc_check_discord() {
    local _reg
    nc_http_fetch GET "https://discord.com/api/v9/auth/location-metadata" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(nc_body_first '"country_code"[[:space:]]*:[[:space:]]*"[A-Za-z][A-Za-z]"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')")
    case "$_h_code" in
        200) nc_conn_done available "$_reg" ;;
        403) nc_conn_done restricted "$_reg" "HTTP 403" ;;
        *) nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "$_reg" "HTTP $_h_code" ;;
    esac
}

nc_check_prime() {
    local _reg
    nc_http_fetch GET "https://www.primevideo.com" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _reg=$(nc_conn_region "$(nc_body_first '"currentTerritory"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')")
    if nc_body_has "isServiceRestricted"; then
        nc_conn_done unsupported-region "$_reg" "页面标记服务受限"
        return 0
    fi
    if [ -n "$_reg" ]; then
        nc_conn_done available "$_reg"
        return 0
    fi
    case "$_h_code" in
        2??) nc_conn_done failed "" "未找到地区字段（可能被重定向到登录页）" ;;
        *) nc_conn_done "$(nc_conn_status_from_code "$_h_code")" "" "HTTP $_h_code" ;;
    esac
}

nc_check_netflix() {
    local _first _reg _second
    # 1) fast.com 的 country 字段最能反映真实出口
    nc_http_fetch GET "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5" "$_c_body"
    if [ "$_h_code" -gt 0 ]; then
        nc_conn_mark
        if [ "$_h_code" = "403" ]; then
            nc_conn_done blocked "" "fast.com 返回 403"
            return 0
        fi
        _reg=$(nc_conn_region "$(nc_body_first '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')")
        if [ -n "$_reg" ]; then
            nc_conn_done available "$_reg"
            return 0
        fi
    fi

    # 2) 标题页规则
    nc_http_fetch GET "https://www.netflix.com/title/81280792" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    _first=$_h_code
    nc_http_fetch GET "https://www.netflix.com/title/70143836" "$_c_body"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    _second=$_h_code

    case "$_first:$_second" in
        404:404) nc_conn_done originals-only "" "两部版权剧均不可见" ; return 0 ;;
    esac
    if [ "$_first" = "403" ] || [ "$_second" = "403" ]; then
        nc_conn_done unsupported-region "" "标题页返回 403"
        return 0
    fi
    case "$_first" in
        200|301|302) ;;
        *) nc_conn_done "$(nc_conn_status_from_code "$_first")" "" "HTTP $_first"; return 0 ;;
    esac

    nc_http_location "https://www.netflix.com/title/80018499"
    _reg=""
    case "$_c_location" in
        *://*)
            _reg=${_c_location#*://}
            _reg=${_reg#*/}
            _reg=${_reg%%/*}
            _reg=$(nc_conn_region "$_reg")
            ;;
    esac
    nc_conn_done available "$_reg"
}

nc_check_disney() {
    local _assertion _country _form _query _refresh _supported
    # 1) 设备注册，换 assertion
    nc_http_fetch POST "https://disney.api.edge.bamgrid.com/devices" "$_c_body" \
        "application/json; charset=UTF-8" \
        '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' \
        "$NC_DISNEY_AUTH"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    nc_conn_mark
    if [ "$_h_code" = "403" ]; then
        nc_conn_done blocked "" "设备注册返回 403"
        return 0
    fi
    if [ "$_h_code" = "400" ]; then
        nc_conn_done failed "" "设备注册被拒绝（HTTP 400，接口可能已变更）"
        return 0
    fi
    _assertion=$(nc_body_first '"assertion"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    if [ -z "$_assertion" ]; then
        nc_conn_done failed "" "设备注册未返回 assertion（HTTP $_h_code）"
        return 0
    fi

    # 2) 换 refresh_token
    _form="grant_type=urn:ietf:params:oauth:grant-type:token-exchange&latitude=0&longitude=0&platform=browser&subject_token=$_assertion&subject_token_type=urn:bamtech:params:oauth:token-type:device"
    nc_http_fetch POST "https://disney.api.edge.bamgrid.com/token" "$_c_body" \
        "application/x-www-form-urlencoded" "$_form" "$NC_DISNEY_AUTH"
    if [ "$_h_code" -eq 0 ]; then
        nc_conn_fail
        return 0
    fi
    if nc_body_has "forbidden-location" || nc_body_has "403 ERROR"; then
        nc_conn_done blocked "" "token 接口返回 forbidden-location"
        return 0
    fi
    _refresh=$(nc_body_first '"refresh_token"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    if [ -z "$_refresh" ]; then
        nc_conn_done failed "" "token 接口未返回 refresh_token（HTTP $_h_code）"
        return 0
    fi

    # 3) 会话刷新，拿地区与支持状态
    _query='{"query":"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }","variables":{"input":{"refreshToken":"'"$_refresh"'"}}}'
    nc_http_fetch POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" "$_c_body" \
        "application/json" "$_query" "$NC_DISNEY_AUTH"
    if [ "$_h_code" -eq 0 ] || [ "$_h_code" -ge 400 ]; then
        nc_conn_done failed "" "会话接口异常（HTTP ${_h_code:-0}）"
        return 0
    fi
    _country=$(nc_body_first '"countryCode"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    _country=$(nc_conn_region "$_country")
    _supported=$(nc_body_first '"inSupportedLocation"[[:space:]]*:[[:space:]]*(false|true)' | sed 's/.*:[[:space:]]*//')
    case "$_supported" in
        true)  nc_conn_done available "$_country" ;;
        false) nc_conn_done coming-soon "$_country" "该地区尚未上线" ;;
        *)     nc_conn_done failed "$_country" "未返回支持状态" ;;
    esac
}

# ---------- 单服务执行 ----------
nc_conn_check() {
    local _cat _color _id _json _meta _name _oldifs _url _abbr
    _id=$1
    nc_conn_reset "$_id"
    _meta=$(nc_conn_meta "$_id") || { nc_conn_cleanup; return 2; }
    _oldifs=$IFS; IFS='|'; set -- $_meta; IFS=$_oldifs
    _name=$1; _cat=$2; _url=$3; _abbr=$4; _color=$5

    case "$_id" in
        google)       nc_check_reachable "https://www.google.com/generate_204" ;;
        github)       nc_check_reachable "https://github.com/" ;;
        youtube)      nc_check_youtube ;;
        chatgpt)      nc_check_chatgpt ;;
        claude)       nc_check_claude ;;
        gemini)       nc_check_gemini ;;
        netflix)      nc_check_netflix ;;
        disney-plus)  nc_check_disney ;;
        prime-video)  nc_check_prime ;;
        spotify)      nc_check_spotify ;;
        tiktok)       nc_check_tiktok ;;
        discord)      nc_check_discord ;;
        bilibili)     nc_check_bilibili ;;
    esac

    [ -n "$_c_status" ] || nc_conn_done failed "" "未产生检测结果"
    case "$_c_http" in
        ""|*[!0-9]*) _c_http=0 ;;
        *) _c_http=$(printf '%d' "$_c_http" 2>/dev/null) || _c_http=0 ;;
    esac
    case "$_c_delay" in *[!0-9]*|"") _c_delay=0 ;; esac
    _c_region=$(nc_conn_region "$_c_region")

    _json=$(printf '{"id":"%s","status":"%s","label":"%s","http":%s,"latency_ms":%s,"region":"%s","error":"%s","hint":"%s","tested_at":%s}' \
        "$(nc_json_escape "$_id")" "$_c_status" "$(nc_conn_label "$_c_status")" \
        "$_c_http" "$_c_delay" "$(nc_json_escape "$_c_region")" \
        "$(nc_json_escape "$_c_error")" "$(nc_json_escape "$_c_hint")" "$(nc_now)")

    nc_conn_store "$_id" "$_json" || nc_warn "结果写入失败: $_id"
    printf '%s' "$_json"
    nc_conn_cleanup
    return 0
}

nc_conn_tun() {
    ip -4 -o addr show 2>/dev/null \
        | sed -n 's/^[0-9][0-9]*: \([^ ]*\) .*/\1/p' \
        | grep -E '^(tun|Meta|utun|mihomo|sing-box)' 2>/dev/null \
        | head -n 1
}

nc_conn_context_json() {
    local _core _run _tun
    _core=${NC_ACTIVE_CORE:-sing-box}
    if command -v nc_core_running >/dev/null 2>&1 && nc_core_running "$_core" 2>/dev/null; then
        _run=true
    else
        _run=false
    fi
    _tun=$(nc_conn_tun)
    printf '{"core":"%s","running":%s,"tun":"%s","at":%s}' \
        "$(nc_json_safe "$_core")" "$_run" "$(nc_json_safe "$_tun")" "$(nc_now)"
}

# ---------- 聚合读取 ----------
nc_conn_results_json() {
    local _ctx _file _first _id _items _max _tmp
    mkdir -p "$NC_CONN_DIR" 2>/dev/null
    _tmp="$NC_TMP/conn-agg.$$"
    mkdir -p "$NC_TMP" 2>/dev/null
    {
        _first=1
        printf '{'
        for _id in $(nc_conn_ids); do
            _file="$NC_CONN_DIR/$_id.json"
            [ -s "$_file" ] || continue
            head -c 1 "$_file" 2>/dev/null | grep -q '{' || continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            printf '"%s":' "$_id"
            cat "$_file" 2>/dev/null
        done
        printf '}'
    } >"$_tmp" 2>/dev/null
    _items=$(cat "$_tmp" 2>/dev/null)
    rm -f "$_tmp" 2>/dev/null
    case "$_items" in
        "{"*"}") ;;
        *) _items='{}' ;;
    esac

    _max=$(printf '%s' "$_items" | grep -o '"tested_at":[0-9]*' | sed 's/.*://' | sort -n | tail -n 1)
    case "$_max" in *[!0-9]*|"") _max=0 ;; esac

    # 升级兼容：新结果目录还是空的，就先展示旧版聚合结果
    if [ "$_items" = "{}" ] && [ -s "$NC_RUN/connectivity.json" ] \
        && head -c 1 "$NC_RUN/connectivity.json" 2>/dev/null | grep -q '{'; then
        cat "$NC_RUN/connectivity.json" 2>/dev/null
        return 0
    fi

    _ctx=$(nc_conn_context_json)
    printf '{"tested_at":%s,"context":%s,"results":%s}' "$_max" "$_ctx" "$_items"
}

# 兼容旧接口
nc_conn_probe_json() { nc_conn_check "$1"; }

nc_conn_list_json() {
    local _abbr _cat _color _first _id _meta _name _oldifs _url
    _first=1
    printf '['
    for _id in $(nc_conn_ids); do
        _meta=$(nc_conn_meta "$_id") || continue
        _oldifs=$IFS; IFS='|'; set -- $_meta; IFS=$_oldifs
        _name=$1; _cat=$2; _url=$3; _abbr=$4; _color=$5
        [ "$_first" = "1" ] || printf ','
        _first=0
        printf '{"id":"%s","name":"%s","category":"%s","url":"%s","abbr":"%s","color":"%s"}' \
            "$(nc_json_escape "$_id")" "$(nc_json_escape "$_name")" "$_cat" \
            "$(nc_json_escape "$_url")" "$(nc_json_escape "$_abbr")" "$(nc_json_escape "$_color")"
    done
    printf ']'
}

nc_conn_test_locked() {
    local _id _n _failed _start _ts
    mkdir -p "$NC_CONN_DIR" "$NC_TMP" 2>/dev/null
    NC_CONN_CLIENT=$(nc_http_client)
    export NC_CONN_CLIENT
    _start=$(nc_now)
    _n=0
    for _id in $(nc_conn_ids); do
        _n=$((_n + 1))
        (nc_conn_check "$_id" >/dev/null 2>&1) &
        if [ $((_n % NC_CONN_JOBS)) -eq 0 ]; then wait; fi
    done
    wait

    # 只看本轮写入的结果：崩溃/超时留下的旧文件不能算成功
    _failed=0
    for _id in $(nc_conn_ids); do
        _ts=""
        [ -s "$NC_CONN_DIR/$_id.json" ] && _ts=$(sed -n 's/.*"tested_at":\([0-9]*\).*/\1/p' "$NC_CONN_DIR/$_id.json" 2>/dev/null | tail -n 1)
        case "$_ts" in
            ""|*[!0-9]*) _failed=$((_failed + 1)) ;;
            *) [ "$_ts" -ge "$_start" ] || _failed=$((_failed + 1)) ;;
        esac
    done
    if [ "$_failed" -gt 0 ]; then
        nc_warn "服务状态检测完成: $_n 项，$_failed 项无结果"
    else
        nc_info "服务状态检测完成: $_n 项"
    fi
}

nc_conn_test() {
    # 同一时间只允许一轮全量测试，避免两轮结果互相覆盖
    if command -v flock >/dev/null 2>&1; then
        (
            flock -n 9 2>/dev/null || { nc_warn "已有连通性测试在运行"; exit 0; }
            nc_conn_test_locked
        ) 9>"$NC_RUN/connectivity.lock"
    else
        nc_conn_test_locked
    fi
}
