#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 连通性 / 服务状态
#
# 这不是简单的 HTTP 200 探测：参考 FlClash 的 service status 规则，
# 通过真实页面/API 的状态码、页面内容和地区字段判断可用性。
# 覆盖 13 项服务；结果写入 run/connectivity.json。
# ============================================================

NC_CONN_RESULTS="$NC_RUN/connectivity.json"
NC_CONN_TIMEOUT="${NC_CONN_TIMEOUT:-10}"
NC_CONN_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
NC_DISNEY_AUTH="Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"

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
        401|403|429|451) printf 'restricted' ;;
        *) printf 'unavailable' ;;
    esac
}

nc_conn_region() {
    local _r
    _r=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    case "$_r" in
        CHN) _r=CN ;; RUS) _r=RU ;; BLR) _r=BY ;; CUB) _r=CU ;;
        IRN) _r=IR ;; PRK) _r=KP ;; SYR) _r=SY ;; HKG) _r=HK ;; MAC) _r=MO ;;
    esac
    case "$_r" in
        [A-Z][A-Z]|[A-Z][A-Z][A-Z]) printf '%s' "$_r" ;;
        *) printf '' ;;
    esac
}

nc_conn_region_blocked() {
    local _needle _word
    _needle=$1
    for _word in $2; do
        [ "$_needle" = "$_word" ] && return 0
    done
    return 1
}

# ---------- HTTP 层 ----------
nc_conn_reset() {
    _c_http=0
    _c_delay=0
    _c_effective=""
    _c_error=""
    _c_status=""
    _c_region=""
    _c_location=""
    _c_tmp="$NC_TMP/conn-${1}-$$"
    mkdir -p "$_c_tmp" 2>/dev/null
    _c_body="$_c_tmp/body"
    _c_err="$_c_tmp/err"
    _c_hdr="$_c_tmp/headers"
}

nc_conn_request() {
    local _args _eff _http _meta _ms _rc _time
    _url=$1
    _bodyout=$2
    shift 2
    _meta=$("$NC_CURL" -L -sS --compressed -A "$NC_CONN_UA" \
        --connect-timeout 5 --max-time "$NC_CONN_TIMEOUT" "$@" \
        -o "$_bodyout" -w '%{http_code} %{time_total} %{url_effective}' "$_url" 2>"$_c_err")
    _rc=$?
    set -- $_meta
    _http=${1:-0}
    _time=${2:-0}
    _eff=${3:-$_url}
    case "$_http" in *[!0-9]*|"") _http=0 ;; esac
    _http=$(printf '%d' "$_http" 2>/dev/null) || _http=0
    case "$_time" in *[!0-9.]*|"") _time=0 ;; esac
    _ms=$(awk -v t="$_time" 'BEGIN { printf "%d", t * 1000 }' 2>/dev/null)
    case "$_ms" in *[!0-9]*|"") _ms=0 ;; esac
    _c_http=$_http
    _c_effective=$_eff
    [ "$_c_delay" -eq 0 ] && _c_delay=$_ms
    if [ "$_rc" -ne 0 ] || [ "$_http" = "0" ]; then
        _c_error=$(head -n 1 "$_c_err" 2>/dev/null | tr -d '\r' | cut -c1-220)
        case "$_c_error" in
            *timed?out*|*timeout*|*"Operation timed out"*) _c_status=timeout ;;
            *) _c_status=failed ;;
        esac
        return 1
    fi
    return 0
}

nc_conn_get() {
    local _url
    _url=$1
    shift
    nc_conn_request "$_url" "$_c_body" "$@"
}

nc_conn_post() {
    local _ct _payload _url
    _url=$1
    _payload=$2
    _ct=$3
    shift 3
    _c_http=0
    nc_conn_request "$_url" "$_c_body" -H "content-type: $_ct" -d "$_payload" "$@"
}

nc_conn_head_location() {
    local _url
    _url=$1
    "$NC_CURL" -sS --compressed -A "$NC_CONN_UA" --max-time "$NC_CONN_TIMEOUT" \
        -D "$_c_hdr" -o /dev/null "$_url" 2>/dev/null
    _c_location=$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$_c_hdr" 2>/dev/null | tr -d '\r' | head -n 1)
}

nc_conn_body_has() {
    grep -a -qi -F -- "$1" "$_c_body" 2>/dev/null
}

nc_conn_body_match() {
    grep -a -oE -- "$1" "$_c_body" 2>/dev/null | head -n 1
}

nc_conn_fail_status() {
    [ -n "$_c_status" ] || _c_status=failed
}

# ---------- 服务规则 ----------
nc_check_reachable() {
    local _url
    _url=$1
    nc_conn_get "$_url"
    [ -n "$_c_status" ] && return 0
    _c_status=$(nc_conn_status_from_code "$_c_http")
}

nc_check_claude() {
    nc_conn_get "https://claude.ai/cdn-cgi/trace" || return 0
    _c_region=$(nc_conn_region "$(sed -n 's/^loc=//p' "$_c_body" 2>/dev/null | head -n 1)")
    [ -n "$_c_region" ] || { _c_status=failed; return 0; }
    _c_status=available
    nc_conn_region_blocked "$_c_region" "AF BY CN CU HK IR KP MO RU SY" && _c_status=unsupported-region
}

nc_check_chatgpt() {
    local _reg
    nc_conn_get "https://ios.chat.openai.com/" || return 0
    if nc_conn_body_has "you may be connected to a disallowed isp"; then
        _c_status=disallowed-isp
    elif nc_conn_body_has "sorry, you have been blocked"; then
        _c_status=blocked
    elif nc_conn_body_has "request is not allowed. please try again later."; then
        _c_status=available
    else
        _c_status=failed
    fi
    nc_conn_get "https://chat.openai.com/cdn-cgi/trace" >/dev/null 2>&1 && {
        _reg=$(nc_conn_region "$(sed -n 's/^loc=//p' "$_c_body" 2>/dev/null | head -n 1)")
        [ -n "$_reg" ] && _c_region=$_reg
    }
    nc_conn_get "https://api.openai.com/compliance/cookie_requirements" >/dev/null 2>&1 && \
        nc_conn_body_has "unsupported_country" && _c_status=unsupported-region
}

nc_check_gemini() {
    local _code _raw
    nc_conn_get "https://gemini.google.com" || return 0
    _code=$(nc_conn_body_match ',2,1,200,"[A-Z][A-Z][A-Z]' | sed 's/.*"//')
    [ -n "$_code" ] || { _c_status=failed; return 0; }
    _raw=$_code
    _c_region=$(nc_conn_region "$_code")
    _c_status=available
    # FlClash 的 Gemini 限制列表是三字码；必须用原始值匹配，
    # 不能先规范成 CN 再和 CHN 列表比较。
    nc_conn_region_blocked "$_raw" "CHN RUS BLR CUB IRN PRK SYR HKG MAC" && _c_status=unsupported-region
}

nc_check_youtube() {
    local _raw
    nc_conn_get "https://www.youtube.com/premium?hl=en" || return 0
    _c_region=$(grep -aoE '"GL"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' "$_c_body" 2>/dev/null | head -n 1 | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    [ -n "$_c_region" ] || _c_region=$(grep -aoE '"countryCode"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' "$_c_body" 2>/dev/null | head -n 1 | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    [ -n "$_c_region" ] || _c_region=$(grep -aoE '"country_code"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' "$_c_body" 2>/dev/null | head -n 1 | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')
    [ -n "$_c_region" ] || _c_region=$(tr '\n' ' ' <"$_c_body" 2>/dev/null | sed -n 's/.*id="country-code"[^>]*>[[:space:]]*\([A-Za-z][A-Za-z][A-Za-z]*\).*/\1/p' | head -n 1)
    _c_region=$(nc_conn_region "$_c_region")
    if nc_conn_body_has "youtube premium is not available in your country" || \
       nc_conn_body_has "premium is not available in your country" || \
       nc_conn_body_has "premium is not available in your region"; then
        _c_status=unsupported-region
    elif [ "$_c_http" -ge 200 ] && [ "$_c_http" -lt 300 ] && \
         { nc_conn_body_has "youtube premium" || nc_conn_body_has "ad-free" || nc_conn_body_has '"browseid":"spunlimited"'; }; then
        _c_status=available
    else
        _c_status=$(nc_conn_status_from_code "$_c_http")
    fi
}

nc_check_spotify() {
    local _path _code
    nc_conn_get "https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json" || return 0
    _c_region=$(nc_conn_region "$(nc_conn_body_match '"countryCode"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')")
    [ -n "$_c_region" ] || {
        _path=${_c_effective#*://}; _path=${_path#*/}; _path=${_path%%/*}
        _c_region=$(nc_conn_region "${_path%%-*}")
    }
    case "$_c_http" in
        403|451) _c_status=unsupported-region ;;
        *) if [ "$_c_http" -lt 200 ] || [ "$_c_http" -ge 300 ]; then
               _c_status=$(nc_conn_status_from_code "$_c_http")
           elif nc_conn_body_has "not available in your country"; then
               _c_status=unsupported-region
           else
               _c_status=available
           fi ;;
    esac
}

nc_check_tiktok() {
    local _raw
    nc_conn_get "https://www.tiktok.com/" || return 0
    _raw=$(nc_conn_body_match '"webapp\.app-context"[^}]*"region"[[:space:]]*:[[:space:]]*"[^"]*"')
    if [ -n "$_raw" ]; then
        _c_region=$(nc_conn_region "$(printf '%s' "$_raw" | sed 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')")
    fi
    case "$_c_http" in
        403|451) _c_status=unsupported-region ;;
        *)
            if [ "$_c_http" -lt 200 ] || [ "$_c_http" -ge 300 ]; then
                _c_status=failed
            elif nc_conn_body_has "access denied" || nc_conn_body_has "not available in your region" || nc_conn_body_has "tiktok is not available"; then
                _c_status=unsupported-region
            else
                _c_status=available
            fi
            ;;
    esac
}

nc_check_bilibili() {
    local _code
    nc_conn_get "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi" || return 0
    _code=$(nc_conn_body_match '^[[:space:]]*\{[[:space:]]*"code"[[:space:]]*:[[:space:]]*-?[0-9]+' | sed 's/.*"code"[[:space:]]*:[[:space:]]*//; s/[^0-9-].*//')
    case "$_code" in
        0) _c_status=available; _c_region=CN ;;
        -10403)
            nc_conn_get "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi" || return 0
            _code=$(nc_conn_body_match '^[[:space:]]*\{[[:space:]]*"code"[[:space:]]*:[[:space:]]*-?[0-9]+' | sed 's/.*"code"[[:space:]]*:[[:space:]]*//; s/[^0-9-].*//')
            [ "$_code" = "0" ] && _c_status=available || _c_status=unsupported-region
            ;;
        *) _c_status=failed ;;
    esac
}

nc_check_discord() {
    nc_conn_get "https://discord.com/api/v9/auth/location-metadata" || return 0
    _c_status=$(nc_conn_status_from_code "$_c_http")
    if [ "$_c_status" = "available" ]; then
        _c_region=$(nc_conn_region "$(nc_conn_body_match '"country_code"[[:space:]]*:[[:space:]]*"[A-Za-z][A-Za-z]"' | sed 's/.*"\([A-Za-z][A-Za-z]\)"/\1/')")
    fi
}

nc_check_prime() {
    nc_conn_get "https://www.primevideo.com" || return 0
    if nc_conn_body_has "isServiceRestricted"; then
        _c_status=unsupported-region
        return 0
    fi
    _c_region=$(nc_conn_region "$(nc_conn_body_match '"currentTerritory"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')")
    if [ -n "$_c_region" ]; then
        _c_status=available
    elif [ "$_c_http" -ge 200 ] && [ "$_c_http" -lt 300 ]; then
        _c_status=failed
    else
        _c_status=$(nc_conn_status_from_code "$_c_http")
    fi
}

nc_check_netflix() {
    local _first _second
    if nc_conn_get "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5"; then
        if [ "$_c_http" = "403" ]; then
            _c_status=blocked
            return 0
        fi
        if [ "$_c_http" -ge 200 ] && [ "$_c_http" -lt 300 ]; then
            _c_region=$(nc_conn_region "$(nc_conn_body_match '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')")
            if [ -n "$_c_region" ]; then
                _c_status=available
                return 0
            fi
        fi
    fi
    # fast.com 失败（TLS/网络拦截）时继续走标题页规则，而不是直接判失败
    _c_status=""
    _c_error=""

    nc_conn_get "https://www.netflix.com/title/81280792" || return 0
    _first=$_c_http
    nc_conn_get "https://www.netflix.com/title/70143836" || return 0
    _second=$_c_http
    case "$_first:$_second" in
        404:404) _c_status=originals-only ;;
        *403*|403:*) _c_status=unsupported-region ;;
        *)
            case "$_first" in 200|301|302) _c_status=available ;; *) _c_status=$(nc_conn_status_from_code "$_first") ;; esac
            [ "$_c_status" = "available" ] && {
                nc_conn_head_location "https://www.netflix.com/title/80018499"
                _path=${_c_location#*://}; _path=${_path#*/}; _path=${_path%%/*}
                _c_region=$(nc_conn_region "${_path%%-*}")
            }
            ;;
    esac
}

nc_check_disney() {
    local _assertion _country _details _form _query _refresh _supported _token
    nc_conn_post "https://disney.api.edge.bamgrid.com/devices" \
        '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' \
        "application/json; charset=UTF-8" \
        -H "authorization: $NC_DISNEY_AUTH" || return 0
    if [ "$_c_http" = "403" ]; then _c_status=blocked; return 0; fi
    _assertion=$(nc_conn_body_match '"assertion"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    [ -n "$_assertion" ] || { _c_status=failed; return 0; }

    _form="grant_type=urn:ietf:params:oauth:grant-type:token-exchange&latitude=0&longitude=0&platform=browser&subject_token=$_assertion&subject_token_type=urn:bamtech:params:oauth:token-type:device"
    nc_conn_post "https://disney.api.edge.bamgrid.com/token" "$_form" \
        "application/x-www-form-urlencoded" \
        -H "authorization: $NC_DISNEY_AUTH" || return 0
    if nc_conn_body_has "forbidden-location" || nc_conn_body_has "403 ERROR"; then
        _c_status=blocked
        return 0
    fi
    _refresh=$(nc_conn_body_match '"refresh_token"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    [ -n "$_refresh" ] || { _c_status=failed; return 0; }

    _query='{"query":"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }","variables":{"input":{"refreshToken":"'"$_refresh"'"}}}'
    nc_conn_post "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" "$_query" \
        "application/json" -H "authorization: $NC_DISNEY_AUTH" || return 0
    _details=$_c_status
    if [ "$_c_http" -ge 400 ] || [ ! -s "$_c_body" ]; then _c_status=failed; return 0; fi
    _country=$(nc_conn_body_match '"countryCode"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')
    _c_region=$(nc_conn_region "$_country")
    _supported=$(nc_conn_body_match '"inSupportedLocation"[[:space:]]*:[[:space:]]*(false|true)' | sed 's/.*:[[:space:]]*//')
    case "$_supported" in
        true) _c_status=available ;;
        false) _c_status=coming-soon ;;
        *) _c_status=${_details:-failed}; [ "$_c_status" = "available" ] && _c_status=failed ;;
    esac
}

nc_conn_check() {
    local _cat _color _id _meta _name _oldifs _url _abbr
    _id=$1
    nc_conn_reset "$_id"
    _c_status=""
    _meta=$(nc_conn_meta "$_id") || { rm -rf "$_c_tmp"; return 2; }
    _oldifs=$IFS; IFS='|'; set -- $_meta; IFS=$_oldifs
    _name=$1; _cat=$2; _url=$3; _abbr=$4; _color=$5
    case "$_id" in
        google) nc_check_reachable "https://www.google.com/generate_204" ;;
        github) nc_check_reachable "https://github.com/" ;;
        youtube) nc_check_youtube ;;
        chatgpt) nc_check_chatgpt ;;
        claude) nc_check_claude ;;
        gemini) nc_check_gemini ;;
        netflix) nc_check_netflix ;;
        disney-plus) nc_check_disney ;;
        prime-video) nc_check_prime ;;
        spotify) nc_check_spotify ;;
        tiktok) nc_check_tiktok ;;
        discord) nc_check_discord ;;
        bilibili) nc_check_bilibili ;;
    esac
    nc_conn_fail_status
    printf '{"id":"%s","status":"%s","label":"%s","http":%s,"latency_ms":%s,"region":"%s","error":"%s","tested_at":%s}' \
        "$(nc_json_escape "$_id")" "$_c_status" "$(nc_conn_label "$_c_status")" \
        "${_c_http:-0}" "${_c_delay:-0}" "$(nc_json_escape "${_c_region:-}")" \
        "$(nc_json_escape "${_c_error:-}")" "$(nc_now)"
    rm -rf "$_c_tmp" 2>/dev/null
}

nc_conn_probe_json() {
    nc_conn_check "$1"
}

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

nc_conn_results_json() {
    if [ -s "$NC_CONN_RESULTS" ] && head -c 1 "$NC_CONN_RESULTS" 2>/dev/null | grep -q '{'; then
        cat "$NC_CONN_RESULTS"
    else
        printf '{"tested_at":0,"region":"","results":{}}'
    fi
}

nc_conn_test() {
    local _file _first _id _n _tmp
    _tmp="$NC_TMP/conn-$$"
    mkdir -p "$_tmp" 2>/dev/null
    _n=0
    for _id in $(nc_conn_ids); do
        _n=$((_n + 1))
        (nc_conn_check "$_id" >"$_tmp/$_id.json") &
        if [ $((_n % 4)) -eq 0 ]; then wait; fi
    done
    wait

    _file="$NC_CONN_RESULTS.tmp.$$"
    {
        printf '{"tested_at":%s,"region":"","results":{' "$(nc_now)"
        _first=1
        for _id in $(nc_conn_ids); do
            [ -s "$_tmp/$_id.json" ] || continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            printf '"%s":' "$_id"
            cat "$_tmp/$_id.json"
        done
        printf '}}'
    } >"$_file" 2>/dev/null
    mv -f "$_file" "$NC_CONN_RESULTS" 2>/dev/null
    rm -rf "$_tmp" 2>/dev/null
    nc_info "服务状态检测完成: $_n 项"
}
