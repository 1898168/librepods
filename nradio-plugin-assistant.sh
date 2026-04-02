#!/bin/sh
set -eu
umask 077

SCRIPT_TITLE="NRadio 官方系统插件安装助手"
SCRIPT_SIGNATURE="Designed by maye"
SCRIPT_DISCLAIMER="此脚本非盈利性质，纯属免费，禁止付费传播"
TPL="/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm"
CFG="/etc/config/appcenter"
FEEDS="/etc/opkg/distfeeds.conf"
BACKUP_DIR="/root/nradio-plugin-fix"
STATE_DIR="/root/.nradio-plugin-menu"
RUNTIME_STATE_FILE="$STATE_DIR/openvpn_runtime.conf"
ROUTE_STATE_FILE="$STATE_DIR/openvpn_routes.conf"
RUNTIME_CA_FILE="$STATE_DIR/openvpn_ca.crt"
RUNTIME_CERT_FILE="$STATE_DIR/openvpn_client.crt"
RUNTIME_KEY_FILE="$STATE_DIR/openvpn_client.key"
RUNTIME_TLS_FILE="$STATE_DIR/openvpn_tls.key"
RUNTIME_EXTRA_FILE="$STATE_DIR/openvpn_extra.conf"
ROUTE_LIST_FILE="$STATE_DIR/openvpn_routes.list"
ROUTE_MAP_LIST_FILE="$STATE_DIR/openvpn_map_peers.list"
WORKDIR="/tmp/nradio-plugin-fix.$$"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
OPENCLASH_BRANCH="${OPENCLASH_BRANCH:-master}"
OPENCLASH_MIRRORS="${OPENCLASH_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://fastly.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH}}"
OPENCLASH_CORE_VERSION_MIRRORS="${OPENCLASH_CORE_VERSION_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev}"
OPENCLASH_CORE_SMART_MIRRORS="${OPENCLASH_CORE_SMART_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart}"
OPENCLASH_GEOASN_MIRRORS="${OPENCLASH_GEOASN_MIRRORS:-https://testingcf.jsdelivr.net/gh/xishang0128/geoip@release https://cdn.jsdelivr.net/gh/xishang0128/geoip@release https://fastly.jsdelivr.net/gh/xishang0128/geoip@release}"
ADGUARDHOME_VERSION="${ADGUARDHOME_VERSION:-1.8-9}"
ADGUARDHOME_IPK_URLS="${ADGUARDHOME_IPK_URLS:-https://ghproxy.net/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk https://mirror.ghproxy.com/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk https://gh-proxy.com/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk}"
ADGUARDHOME_CORE_MIRRORS="${ADGUARDHOME_CORE_MIRRORS:-https://static.adtidy.org/adguardhome/release}"
OPENVPN_VERSION="${OPENVPN_VERSION:-}"
DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-15}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-900}"
DOWNLOAD_RETRY="${DOWNLOAD_RETRY:-5}"

cleanup() {
    rm -rf "$WORKDIR"
}

abort_script() {
    cleanup
    printf '\nCancelled\n' >&2
    exit 130
}

trap cleanup EXIT
trap abort_script INT TERM

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

confirm_or_exit() {
    prompt="$1"
    answer=""
    printf '%s [y/N]: ' "$prompt"
    read -r answer || die "input cancelled"
    case "$answer" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            log "cancelled"
            exit 0
            ;;
    esac
}

confirm_default_yes() {
    prompt="$1"
    answer=""
    printf '%s [Y/n]: ' "$prompt"
    read -r answer || die "input cancelled"
    case "$answer" in
        n|N|no|NO)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

prompt_with_default() {
    prompt="$1"
    default_value="$2"
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value"
    else
        printf '%s: ' "$prompt"
    fi
    read -r PROMPT_RESULT || die "input cancelled"
    [ -n "$PROMPT_RESULT" ] || PROMPT_RESULT="$default_value"
}

require_root() {
    [ "$(id -u)" = "0" ] || die "please run as root"
}

download_file() {
    url="$1"
    out="$2"
    tmp_out="$out.tmp"

    [ -n "$url" ] || return 1

    printf 'downloading: %s\n' "$url" >&2

    if command -v curl >/dev/null 2>&1; then
        if ! curl -C - -LfS --progress-bar --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" --retry "$DOWNLOAD_RETRY" --retry-delay 2 "$url" -o "$tmp_out"; then
            rm -f "$tmp_out"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -c --no-check-certificate -T "$DOWNLOAD_MAX_TIME" -t "$DOWNLOAD_RETRY" -O "$tmp_out" "$url"; then
            rm -f "$tmp_out"
            return 1
        fi
    elif command -v uclient-fetch >/dev/null 2>&1; then
        printf 'note: uclient-fetch does not show full progress bar, downloading anyway...\n' >&2
        if ! uclient-fetch -T "$DOWNLOAD_MAX_TIME" -q -O "$tmp_out" "$url"; then
            rm -f "$tmp_out"
            return 1
        fi
    else
        die "need curl, wget or uclient-fetch"
    fi

    [ -s "$tmp_out" ] || { rm -f "$tmp_out"; return 1; }
    mv "$tmp_out" "$out"
}

download_from_mirrors() {
    rel="$1"
    out="$2"
    base_list="${3:-$OPENCLASH_MIRRORS}"

    for base in $base_list; do
        if download_file "$base/$rel" "$out"; then
            printf '%s\n' "$base"
            return 0
        fi
    done

    return 1
}

get_openclash_core_arch() {
    machine="$(uname -m 2>/dev/null || true)"

    case "$machine" in
        x86_64) printf '%s\n' amd64 ;;
        i386|i686) printf '%s\n' 386 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        armv7l|armv7) printf '%s\n' armv7 ;;
        armv6l|armv6) printf '%s\n' armv6 ;;
        armv5tel|armv5*) printf '%s\n' armv5 ;;
        mips64el|mips64le) printf '%s\n' mips64le ;;
        mips64) printf '%s\n' mips64 ;;
        mipsel|mipsle)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mipsle-softfloat
            else
                printf '%s\n' mipsle-hardfloat
            fi
            ;;
        mips)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mips-softfloat
            else
                printf '%s\n' mips-hardfloat
            fi
            ;;
        *) return 1 ;;
    esac
}

install_openclash_smart_core() {
    core_arch="$(get_openclash_core_arch 2>/dev/null || true)"
    [ -n "$core_arch" ] || die "failed to detect OpenClash smart core architecture"

    mkdir -p "$WORKDIR/openclash/core" /etc/openclash/core
    core_version_file="$WORKDIR/openclash/core_version"
    smart_core_tar="$WORKDIR/openclash/clash-linux-${core_arch}.tar.gz"
    smart_core_dir="/etc/openclash/core"

    log "tip: downloading OpenClash smart core version file via CDN..."
    download_from_mirrors "core_version" "$core_version_file" "$OPENCLASH_CORE_VERSION_MIRRORS" || die "failed to fetch OpenClash smart core version file from CDN mirrors"
    smart_core_ver="$(sed -n '2p' "$core_version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || smart_core_ver="$(sed -n '1p' "$core_version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || die "failed to parse OpenClash smart core version"

    log "tip: downloading OpenClash smart core v$smart_core_ver for $core_arch via CDN..."
    download_from_mirrors "clash-linux-${core_arch}.tar.gz" "$smart_core_tar" "$OPENCLASH_CORE_SMART_MIRRORS" || die "failed to fetch OpenClash smart core from CDN mirrors"
    [ -s "$smart_core_tar" ] || die "OpenClash smart core download failed"

    for existing in "$smart_core_dir"/clash*; do
        [ -f "$existing" ] && backup_file "$existing"
    done

    tar -xzf "$smart_core_tar" -C "$smart_core_dir" >/dev/null 2>&1 || die "failed to extract OpenClash smart core"
    smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ && $0 ~ /(^|\/)clash([._-]|$)/ { print; exit }')"
    [ -n "$smart_core_entry" ] || smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ { print; exit }')"
    smart_core_entry_target="${smart_core_entry#./}"
    smart_core_binary="$(basename "$smart_core_entry_target" 2>/dev/null || true)"
    [ -n "$smart_core_binary" ] || die "failed to locate extracted smart core binary"

    case "$smart_core_binary" in
        clash_meta)
            ;;
        *)
            mv -f "$smart_core_dir/$smart_core_binary" "$smart_core_dir/clash_meta" 2>/dev/null || ln -sf "$smart_core_binary" "$smart_core_dir/clash_meta"
            ;;
    esac

    [ -e "$smart_core_dir/clash" ] || ln -sf clash_meta "$smart_core_dir/clash"
    chmod 755 "$smart_core_dir"/clash* 2>/dev/null || true

    mkdir -p /etc/openclash
    printf '%s\n%s\n' "$(sed -n '1p' "$core_version_file")" "$(sed -n '2p' "$core_version_file")" > /etc/openclash/core_version
    chmod 644 /etc/openclash/core_version 2>/dev/null || true

    geoasn_mmdb="$WORKDIR/openclash/GeoLite2-ASN.mmdb"
    log "tip: downloading OpenClash ASN.mmdb via CDN..."
    if download_from_mirrors "GeoLite2-ASN.mmdb" "$geoasn_mmdb" "$OPENCLASH_GEOASN_MIRRORS"; then
        backup_file /etc/openclash/ASN.mmdb
        cp -f "$geoasn_mmdb" /etc/openclash/ASN.mmdb
        chmod 644 /etc/openclash/ASN.mmdb 2>/dev/null || true
    else
        log "note:     ASN.mmdb CDN download failed, will rely on runtime fallback"
    fi

    log "done"
    log "core:     OpenClash smart"
    log "version:  $smart_core_ver"
    log "arch:     $core_arch"
    log "path:     $smart_core_dir"
}

download_from_urls() {
    out="$1"
    shift

    for url in "$@"; do
        if download_file "$url" "$out"; then
            printf '%s\n' "$url"
            return 0
        fi
    done

    return 1
}

backup_file() {
    path="$1"
    [ -f "$path" ] || return 0

    backup_path="$BACKUP_DIR$path.$TS.bak"
    mkdir -p "$(dirname "$backup_path")"
    cp "$path" "$backup_path"
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

save_openvpn_runtime_state() {
    ensure_state_dir
    cp "$ca_tmp" "$RUNTIME_CA_FILE" 2>/dev/null || true
    [ -f "$cert_tmp" ] && cp "$cert_tmp" "$RUNTIME_CERT_FILE" 2>/dev/null || true
    [ -f "$key_tmp" ] && cp "$key_tmp" "$RUNTIME_KEY_FILE" 2>/dev/null || true
    [ -f "$ta_tmp" ] && cp "$ta_tmp" "$RUNTIME_TLS_FILE" 2>/dev/null || true
    [ -f "$extra_tmp" ] && cp "$extra_tmp" "$RUNTIME_EXTRA_FILE" 2>/dev/null || true
}

load_openvpn_runtime_state() {
    ensure_state_dir
}

save_openvpn_route_state() {
    ensure_state_dir

    route_nat_save='n'
    [ "$route_nat" = '1' ] && route_nat_save='y'
    route_forward_save='n'
    [ "$route_forward" = '1' ] && route_forward_save='y'
    route_enhanced_save='n'
    [ "${route_enhanced:-0}" = '1' ] && route_enhanced_save='y'
    route_map_enable_save='n'
    [ "${route_map_enable:-0}" = '1' ] && route_map_enable_save='y'
    {
        printf 'ROUTE_LAN_IF=%s\n' "$(shell_quote "$lan_if")"
        printf 'ROUTE_TUN_IF=%s\n' "$(shell_quote "$tun_if")"
        printf 'ROUTE_LAN_SUBNET=%s\n' "$(shell_quote "$lan_subnet")"
        printf 'ROUTE_TUN_SUBNET=%s\n' "$(shell_quote "$tun_subnet")"
        printf 'ROUTE_NAT=%s\n' "$(shell_quote "$route_nat_save")"
        printf 'ROUTE_FORWARD=%s\n' "$(shell_quote "$route_forward_save")"
        printf 'ROUTE_ENHANCED=%s\n' "$(shell_quote "$route_enhanced_save")"
        printf 'ROUTE_MAP_ENABLE=%s\n' "$(shell_quote "$route_map_enable_save")"
        printf 'ROUTE_MAP_IP=%s\n' "$(shell_quote "${map_ip:-}")"
    } > "$ROUTE_STATE_FILE"
    cp "$route_tmp" "$ROUTE_LIST_FILE" 2>/dev/null || true
    if [ "${route_map_enable:-0}" = '1' ] && [ -n "${map_route_tmp:-}" ] && [ -s "$map_route_tmp" ]; then
        cp "$map_route_tmp" "$ROUTE_MAP_LIST_FILE" 2>/dev/null || true
    fi
}

load_openvpn_route_state() {
    ensure_state_dir
    if [ -f "$ROUTE_STATE_FILE" ]; then
        if ! . "$ROUTE_STATE_FILE" 2>/dev/null; then
            rm -f "$ROUTE_STATE_FILE"
        fi
    fi
}

clear_openvpn_route_state_vars() {
    unset ROUTE_LAN_IF ROUTE_TUN_IF ROUTE_LAN_SUBNET ROUTE_TUN_SUBNET ROUTE_NAT ROUTE_FORWARD ROUTE_ENHANCED ROUTE_MAP_ENABLE ROUTE_MAP_IP
}

install_ipk_file() {
    ipk_path="$1"
    label="$2"

    [ -s "$ipk_path" ] || die "$label install failed: missing ipk $ipk_path"

    if ! opkg install "$ipk_path" --force-reinstall >/tmp/nradio-plugin-ipk.install.log 2>&1; then
        sed -n '1,200p' /tmp/nradio-plugin-ipk.install.log >&2
        die "$label install failed"
    fi
}

extract_ipk_archive() {
    ipk_path="$1"
    dest_dir="$2"

    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"

    if tar -xzf "$ipk_path" -C "$dest_dir" >/dev/null 2>&1 && [ -f "$dest_dir/data.tar.gz" ] && [ -f "$dest_dir/control.tar.gz" ]; then
        return 0
    fi

    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"

    if command -v ar >/dev/null 2>&1; then
        (cd "$dest_dir" && ar x "$ipk_path" >/dev/null 2>&1) || true
    else
        (cd "$dest_dir" && busybox ar x "$ipk_path" >/dev/null 2>&1) || true
    fi

    [ -f "$dest_dir/data.tar.gz" ] && [ -f "$dest_dir/control.tar.gz" ] || die "failed to unpack ipk: $ipk_path"
}

get_primary_arch() {
    opkg print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            print $2
            exit
        }
    '
}

repack_ipk_control() {
    src_ipk="$1"
    out_ipk="$2"
    target_arch="$3"
    depends_line="$4"

    repack_dir="$WORKDIR/repack.$(basename "$out_ipk")"
    extract_ipk_archive "$src_ipk" "$repack_dir/pkg"
    mkdir -p "$repack_dir/control"
    tar -xzf "$repack_dir/pkg/control.tar.gz" -C "$repack_dir/control" >/dev/null 2>&1 || die "failed to unpack control: $src_ipk"
    sed -i "s/^Architecture: .*/Architecture: $target_arch/" "$repack_dir/control/control"
    if [ -n "$depends_line" ]; then
        if grep -q '^Depends: ' "$repack_dir/control/control"; then
            sed -i "s/^Depends: .*/Depends: $depends_line/" "$repack_dir/control/control"
        else
            printf 'Depends: %s\n' "$depends_line" >> "$repack_dir/control/control"
        fi
    fi
    tar -czf "$repack_dir/pkg/control.tar.gz" -C "$repack_dir/control" .
    (cd "$repack_dir/pkg" && tar -czf "$out_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
    [ -s "$out_ipk" ] || die "failed to repack ipk: $src_ipk"
}

verify_appcenter_route() {
    plugin_name="$1"
    expect_route="$2"

    sec="$(find_uci_section package_list "$plugin_name")"
    [ -n "$sec" ] || die "$plugin_name verify failed: appcenter package_list missing"
    actual_route="$(uci -q get appcenter.$sec.luci_module_route 2>/dev/null || true)"
    [ "$actual_route" = "$expect_route" ] || die "$plugin_name verify failed: appcenter route mismatch ($actual_route)"
}

ensure_default_feeds() {
    [ -f "$FEEDS" ] || return 0

    mkdir -p "$WORKDIR"
    feeds_tmp="$WORKDIR/distfeeds.default"

    cat > "$feeds_tmp" <<'EOF'
# Unsupported vendor target feeds disabled
# src/gz openwrt_core https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/targets/mediatek/mt7987/packages
src/gz openwrt_base https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/base
src/gz openwrt_luci https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/luci
# Vendor private feed unavailable on Tsinghua mirror
# src/gz openwrt_mtk_openwrt_feed https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/mtk_openwrt_feed
src/gz openwrt_packages https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/packages
src/gz openwrt_routing https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/routing
src/gz openwrt_telephony https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/telephony
EOF

    if ! cmp -s "$feeds_tmp" "$FEEDS"; then
        backup_file "$FEEDS"
        cp "$feeds_tmp" "$FEEDS"
    fi
}

ensure_opkg_update() {
    [ -f "$FEEDS" ] || return 0
    ensure_default_feeds

    if opkg update >/tmp/nradio-plugin-opkg.update.log 2>&1; then
        return 0
    fi

    log "warn: opkg update failed with current configured feeds; keep your existing source unchanged"
}

ensure_packages() {
    missing=""
    for pkg in "$@"; do
        opkg status "$pkg" >/dev/null 2>&1 && continue
        if ! opkg install "$pkg" >/tmp/nradio-plugin-opkg.install.log 2>&1; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        log "warn: missing packages:$missing"
    fi
}

get_feed_url() {
    feed_name="$1"
    awk -v n="$feed_name" '$1=="src/gz" && $2==n {print $3; exit}' "$FEEDS" 2>/dev/null
}

get_feed_package_field() {
    feed_name="$1"
    package_name="$2"
    field_name="$3"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1

    mkdir -p "$WORKDIR/feed-index"
    feed_idx="$WORKDIR/feed-index/${feed_name}.Packages.gz"
    download_file "$feed_url/Packages.gz" "$feed_idx" >/dev/null 2>&1 || return 1

    gzip -dc "$feed_idx" 2>/dev/null | awk -v pkg="$package_name" -v fld="$field_name" '
        $0 == ("Package: " pkg) { found = 1; next }
        found && index($0, fld ": ") == 1 {
            sub("^" fld ": ", "")
            print
            exit
        }
        found && $0 == "" { exit }
    '
}

resolve_feed_package_url() {
    feed_name="$1"
    package_name="$2"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1
    filename="$(get_feed_package_field "$feed_name" "$package_name" Filename)"
    [ -n "$filename" ] || return 1
    printf '%s/%s\n' "$feed_url" "$filename"
}

resolve_package_url_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        url="$(resolve_feed_package_url "$feed_name" "$package_name" 2>/dev/null || true)"
        if [ -n "$url" ]; then
            printf '%s\n' "$url"
            return 0
        fi
    done

    return 1
}

resolve_package_version_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        ver="$(get_feed_package_field "$feed_name" "$package_name" Version 2>/dev/null || true)"
        if [ -n "$ver" ]; then
            printf '%s\n' "$ver"
            return 0
        fi
    done

    return 1
}

find_uci_section() {
    sec_type="$1"
    pkg_name="$2"

    uci show appcenter 2>/dev/null | awk -v st="$sec_type" -v n="$pkg_name" '
        $0 ~ ("^appcenter\\.@" st "\\[[0-9]+\\]=" st "$") {
            line = $0
            sub(/^appcenter\./, "", line)
            sub(/=.*/, "", line)
            sec = line
            next
        }
        sec != "" && $0 == ("appcenter." sec ".name='\''" n "'\''") {
            print sec
            exit
        }
    ' 
}

cleanup_appcenter_route_entries() {
    target_route="$1"

    uci show appcenter 2>/dev/null | awk -v route="$target_route" '
        /^appcenter\.@package_list\[[0-9]+\]=package_list$/ {
            sec=$1
            sub(/^appcenter\./, "", sec)
            sub(/=.*/, "", sec)
            current=sec
            next
        }
        current != "" && $0 == ("appcenter." current ".luci_module_route='"'"'" route "'"'"'") {
            print current
            current=""
        }
    ' | while IFS= read -r list_sec; do
        [ -n "$list_sec" ] || continue
        old_name="$(uci -q get "appcenter.$list_sec.name" 2>/dev/null || true)"
        if [ -n "$old_name" ]; then
            pkg_sec="$(find_uci_section package "$old_name")"
            [ -n "$pkg_sec" ] && uci delete "appcenter.$pkg_sec" >/dev/null 2>&1 || true
        fi
        uci delete "appcenter.$list_sec" >/dev/null 2>&1 || true
    done
}

set_appcenter_entry() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller="$5"
    route="$6"

    cleanup_appcenter_route_entries "$route"

    pkg_sec="$(find_uci_section package "$plugin_name")"
    if [ -z "$pkg_sec" ]; then
        pkg_sec="$(uci add appcenter package)"
    fi

    list_sec="$(find_uci_section package_list "$plugin_name")"
    if [ -z "$list_sec" ]; then
        list_sec="$(uci add appcenter package_list)"
    fi

    uci set "appcenter.$pkg_sec.name=$plugin_name"
    uci set "appcenter.$pkg_sec.version=$version"
    uci set "appcenter.$pkg_sec.size=$size"
    uci set "appcenter.$pkg_sec.status=1"
    uci set "appcenter.$pkg_sec.has_luci=1"
    uci set "appcenter.$pkg_sec.open=1"

    uci set "appcenter.$list_sec.name=$plugin_name"
    uci set "appcenter.$list_sec.pkg_name=$pkg_name"
    uci set "appcenter.$list_sec.parent=$plugin_name"
    uci set "appcenter.$list_sec.size=$size"
    uci set "appcenter.$list_sec.luci_module_file=$controller"
    uci set "appcenter.$list_sec.luci_module_route=$route"
    uci set "appcenter.$list_sec.version=$version"
    uci set "appcenter.$list_sec.has_luci=1"
    uci set "appcenter.$list_sec.type=1"
}

patch_common_template() {
    [ -f "$TPL" ] || die "template not found: $TPL"
    backup_file "$TPL"

    mkdir -p "$WORKDIR"
    tmp1="$WORKDIR/appcenter.1"
    tmp2="$WORKDIR/appcenter.2"
    tmp3="$WORKDIR/appcenter.3"
    css_file="$WORKDIR/appcenter.css"
    js_file="$WORKDIR/appcenter.js"

    cat > "$css_file" <<'EOF'
    .app_frame_box{
        width: 100%;
    }
    .app_frame_nav{
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        padding: 0 15px 12px;
        border-bottom: 1px solid #e5e5e5;
    }
    .app_frame_nav_item{
        display: inline-block;
        padding: 6px 10px;
        color: #666;
        cursor: pointer;
        border-bottom: 2px solid transparent;
    }
    .app_frame_nav_item_active{
        color: #0088cc;
        border-bottom-color: #0088cc;
    }
    .app_frame_box iframe{
        height: 78vh;
        overflow: scroll;
        border: 0;
        width: 100%;
    }
EOF

    cat > "$js_file" <<'EOF'
    function reload_iframe(){
        var iframe_main = $('#sub_frame').contents().find('.main');
        var iframe_container = $('#sub_frame').contents().find('.body-container');
        if(iframe_main)
            $(iframe_main).addClass("inner_main");
        if(iframe_container)
            $(iframe_container).addClass("inner_container");

        try {
            var frame = document.getElementById('sub_frame');
            if (!frame || !frame.src)
                return;

            if (frame.src.indexOf('/admin/services/openclash') === -1 && frame.src.indexOf('/admin/services/AdGuardHome') === -1 && frame.src.indexOf('/nradioadv/system/openvpnfull') === -1)
                return;

            var d = frame.contentWindow.document;
            var hide_selectors = [
                'header',
                '.menu_mobile',
                '.mobile_bg_color.container.body-container.visible-xs-block',
                '.footer',
                '.tail_wave'
            ];

            $.each(hide_selectors, function(index, sel){
                $(d).find(sel).css('display', 'none');
            });

            $(d).find('.container.body-container').not('.visible-xs-block').css({
                'width': '100%',
                'margin': '0',
                'padding': '0 10px'
            });
            $(d).find('.main').css({
                'width': '100%',
                'margin': '0'
            });
            $(d).find('.main-content').css({
                'width': '100%',
                'margin': '0',
                'padding': '0'
            });
            $(d.body).css({
                'margin-top': '0',
                'padding-top': '0'
            });
        }
        catch(e) {}
    }
    function get_app_route_url(route){
        return "<%=controller%>" + route;
    }
    function build_app_iframe(route){
        if(route && route.length > 0)
            return "<iframe id='sub_frame' src='" + get_app_route_url(route) + "' name='subpage'></iframe>";
        return "<iframe id='sub_frame' name='subpage'></iframe>";
    }
    function is_openclash_route(route){
        return route && route.indexOf("admin/services/openclash") === 0;
    }
    function is_adguardhome_route(route){
        return route && route.indexOf("admin/services/AdGuardHome") === 0;
    }
    function get_openclash_frame(route){
        var current_route = route && route.length > 0 ? route : "admin/services/openclash/client";
        if(current_route == "admin/services/openclash")
            current_route = "admin/services/openclash/client";

        var tabs = [
            {route: "admin/services/openclash/client", title: "<%:Overviews%>"},
            {route: "admin/services/openclash/settings", title: "<%:Plugin Settings%>"},
            {route: "admin/services/openclash/config-overwrite", title: "<%:Overwrite Settings%>"},
            {route: "admin/services/openclash/config-subscribe", title: "<%:Config Subscribe%>"},
            {route: "admin/services/openclash/config", title: "<%:Config Manage%>"},
            {route: "admin/services/openclash/log", title: "<%:Server Logs%>"}
        ];

        var sub_web_ht = "<div class='app_frame_box'><div class='app_frame_nav'>";
        $.each(tabs, function(index, tab){
            var active_class = "";
            if(tab.route == current_route)
                active_class = " app_frame_nav_item_active";
            sub_web_ht += "<span class='app_frame_nav_item" + active_class + "' data-route='" + tab.route + "' onclick='switch_app_frame_route(this)'>" + tab.title + "</span>";
        });
        sub_web_ht += "</div>" + build_app_iframe(current_route) + "</div>";

        return sub_web_ht;
    }
    function get_adguardhome_frame(route){
        var current_route = route && route.length > 0 ? route : "admin/services/AdGuardHome/base";
        if(current_route == "admin/services/AdGuardHome")
            current_route = "admin/services/AdGuardHome/base";

        var tabs = [
            {route: "admin/services/AdGuardHome/base", title: "Base Setting"},
            {route: "admin/services/AdGuardHome/manual", title: "Manual Config"},
            {route: "admin/services/AdGuardHome/log", title: "Log"}
        ];

        var sub_web_ht = "<div class='app_frame_box'><div class='app_frame_nav'>";
        $.each(tabs, function(index, tab){
            var active_class = "";
            if(tab.route == current_route)
                active_class = " app_frame_nav_item_active";
            sub_web_ht += "<span class='app_frame_nav_item" + active_class + "' data-route='" + tab.route + "' onclick='switch_app_frame_route(this)'>" + tab.title + "</span>";
        });
        sub_web_ht += "</div>" + build_app_iframe(current_route) + "</div>";

        return sub_web_ht;
    }
    function build_app_frame(route){
        if(is_openclash_route(route))
            return get_openclash_frame(route);
        if(is_adguardhome_route(route))
            return get_adguardhome_frame(route);
        return build_app_iframe(route);
    }
    function switch_app_frame_route(obj){
        var route = $(obj).data("route");
        $(".app_frame_nav_item").removeClass("app_frame_nav_item_active");
        $(obj).addClass("app_frame_nav_item_active");
        $("#sub_frame").attr("src", get_app_route_url(route));
    }
    function callback(id,route){
        var sub_web_ht = build_app_frame(route);
        $(".top_menu").removeClass("top_menu_active");
        $(".top_menu").each(function(){
            var cur_index = $(this).data("index");
            if(cur_index == id){
                $(this).addClass("top_menu_active");
            }
        });

        sub_dialogDeal = BootstrapDialog.show({
            type: BootstrapDialog.TYPE_DEFAULT,
            closeByBackdrop: true,
            cssClass:'app_frame',
            title: '',
            message: sub_web_ht,
            onhide:function(){
                $(".modal-dialog").css("display","none");
                $(".top_menu").removeClass("top_menu_active");
                $(".top_menu").eq(0).addClass("top_menu_active");
            },
            onshown:function(){
                reload_iframe();
                $('#sub_frame').on('load', function() {
                    reload_iframe();
                });
            }
        });
    }
EOF

    if grep -q 'app_frame_nav_item' "$TPL"; then
        cp "$TPL" "$tmp1"
    else
        awk -v css_file="$css_file" '
            {
                print
                if ($0 ~ /^    \.modal\.app_frame\.in \.modal-content\{$/) {
                    in_target = 1
                    next
                }
                if (in_target && $0 ~ /^    }$/) {
                    while ((getline extra < css_file) > 0) print extra
                    close(css_file)
                    in_target = 0
                }
            }
        ' "$TPL" > "$tmp1"
    fi

    awk -v js_file="$js_file" '
        BEGIN { skip = 0 }
        {
            if (!skip && $0 ~ /^    function reload_iframe\(\)\{$/) {
                while ((getline extra < js_file) > 0) print extra
                close(js_file)
                skip = 1
                next
            }

            if (skip) {
                if ($0 ~ /^    function app_action\(app_name,action,id,route\)\{$/) {
                    skip = 0
                    print
                }
                next
            }

            print
        }
    ' "$tmp1" > "$tmp2"

    if ! grep -q 'get_openclash_frame(route)' "$tmp2"; then
        die 'template patch failed: openclash block missing'
    fi
    if ! grep -q 'get_adguardhome_frame(route)' "$tmp2"; then
        die 'template patch failed: adguardhome block missing'
    fi

    if grep -q 'db.name == "OpenVPN"' "$tmp2" && grep -q 'db.name == "luci-app-openclash"' "$tmp2" && grep -q 'db.name == "luci-app-adguardhome"' "$tmp2"; then
        cp "$tmp2" "$tmp3"
    else
        awk '
            {
                print
                if ($0 ~ /^            if \(db\.luci_module_route\)$/) {
                    getline
                    print
                    print "            else if (db.name == \"luci-app-openclash\")"
                    print "                open_route = \"admin/services/openclash\";"
                    print "            else if (db.name == \"luci-app-adguardhome\")"
                    print "                open_route = \"admin/services/AdGuardHome\";"
                    print "            else if (db.name == \"OpenVPN\")"
                    print "                open_route = \"nradioadv/system/openvpnfull\";"
                }
            }
        ' "$tmp2" > "$tmp3"
    fi

    if ! grep -q 'db.name == "OpenVPN"' "$tmp3"; then
        die 'template patch failed: OpenVPN fallback missing'
    fi

    cp "$tmp3" "$TPL"
}

refresh_luci_appcenter() {
    rm -f /tmp/luci-indexcache /tmp/infocd/cache/appcenter 2>/dev/null || true
    rm -f /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/infocd restart >/dev/null 2>&1 || true
    /etc/init.d/appcenter restart >/dev/null 2>&1 || true
    sleep 2
}

quiesce_service() {
    init_script="$1"
    [ -f "$init_script" ] || return 0
    "$init_script" stop >/dev/null 2>&1 || true
    "$init_script" disable >/dev/null 2>&1 || true
}

verify_luci_route() {
    route="$1"
    expect="$2"
    out="$WORKDIR/verify.$(echo "$route" | tr '/.' '__').html"
    code="$(curl -m 8 -s -o "$out" -w '%{http_code}' "http://127.0.0.1/cgi-bin/luci/$route" 2>/dev/null || true)"

    case "$code" in
        200|302|403)
            ;;
        *)
            die "$expect verify failed: route $route returned HTTP ${code:-000}"
            ;;
    esac

    if grep -Eq 'Failed to execute|error500|Runtime error|not found!|has no parent node|No page is registered at' "$out" 2>/dev/null; then
        die "$expect verify failed: route $route returned LuCI error page"
    fi
}

verify_file_exists() {
    path="$1"
    label="$2"
    [ -f "$path" ] || die "$label verify failed: missing $path"
}

print_openvpn_runtime_debug() {
    log "debug: openvpn service status"
    /etc/init.d/openvpn status 2>/dev/null || true
    log "debug: /tmp/openvpn-client.log"
    sed -n '1,120p' /tmp/openvpn-client.log 2>/dev/null || true
    log "debug: /tmp/openvpn-runtime-fix.log"
    sed -n '1,120p' /tmp/openvpn-runtime-fix.log 2>/dev/null || true
    log "debug: /var/run/openvpn.custom_config.status"
    sed -n '1,120p' /var/run/openvpn.custom_config.status 2>/dev/null || true
    log "debug: recent logread openvpn"
    logread 2>/dev/null | grep -i openvpn | tail -40 || true
}

print_openvpn_runtime_hints() {
    cert_auth="$1"
    tls_mode="$2"
    proto="$3"
    runtime_log="$4"

    case "$runtime_log" in
        *VERIFY\ KU\ ERROR*|*certificate\ verify\ failed*)
            log "hint: server certificate verification failed; rerun option 4 and choose server verify mode 1 (compat mode)"
            return 0
            ;;
        *'/dev/net/tun'*|*'Cannot open TUN/TAP dev'*|*'TUNSETIFF'*|*'No such device'*)
            log "hint: tun driver is missing or unusable; run option 3 to install/fix tun support first"
            return 0
            ;;
        *liblzo2.so.2*|*lzo1x_*|*__lzo_init_v2*)
            log "hint: OpenVPN runtime dependency liblzo2 is missing or broken; run option 3 again after fixing package installation"
            return 0
            ;;
    esac

    log "hint: check whether your server really requires client certificate/private key"
    [ "$cert_auth" = '1' ] && log "hint: if your server only uses username/password, rerun option 4 and choose n for client certificate/private key"
    [ "$tls_mode" = '0' ] && log "hint: if your server uses tls-auth or tls-crypt, rerun option 4 and choose the correct mode"
    case "$proto" in
        udp6|tcp6-client)
            log "hint: if your server or network does not support IPv6 transport well, rerun option 4 and choose ipv4"
            ;;
    esac
}

resolve_host_record() {
    host="$1"
    family="$2"

    if command -v nslookup >/dev/null 2>&1; then
        if [ "$family" = 'ipv6' ]; then
            nslookup -query=AAAA "$host" 2>/dev/null | awk '/has AAAA address /{print $NF; found=1} /^Address [0-9]*: /{print $NF; found=1} /^[Aa]ddress: /{print $2; found=1} END{if(!found) exit 1}'
        else
            nslookup -query=A "$host" 2>/dev/null | awk '/has address /{print $NF; found=1} /^Address [0-9]*: /{print $NF; found=1} /^[Aa]ddress: /{print $2; found=1} END{if(!found) exit 1}'
        fi
    elif command -v ping6 >/dev/null 2>&1 && [ "$family" = 'ipv6' ]; then
        ping6 -c 1 "$host" 2>/dev/null | awk -F'[()]' '/PING/{print $2; exit}'
    elif command -v ping >/dev/null 2>&1; then
        ping -c 1 "$host" 2>/dev/null | awk -F'[()]' '/PING/{print $2; exit}'
    else
        return 1
    fi
}

get_default_lan_subnet() {
    lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
    lan_mask="$(uci -q get network.lan.netmask 2>/dev/null || true)"

    if [ -n "$lan_ip" ] && [ -n "$lan_mask" ]; then
        case "$lan_mask" in
            255.255.255.0) printf '%s/24\n' "$(printf '%s' "$lan_ip" | awk -F. '{print $1 "." $2 "." $3 ".0"}')"; return 0 ;;
            255.255.0.0) printf '%s/16\n' "$(printf '%s' "$lan_ip" | awk -F. '{print $1 "." $2 ".0.0"}')"; return 0 ;;
            255.0.0.0) printf '%s/8\n' "$(printf '%s' "$lan_ip" | awk -F. '{print $1 ".0.0.0"}')"; return 0 ;;
        esac
    fi

    ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}'
}

get_interface_subnet() {
    iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}'
}

load_openvpn_runtime_defaults_from_profile() {
    ovpn_file="/etc/openvpn/client.ovpn"
    [ -f "$ovpn_file" ] || return 0

    if [ -z "${OVPN_SERVER:-}" ]; then
        OVPN_SERVER="$(awk '$1=="remote" {print $2; exit}' "$ovpn_file" 2>/dev/null || true)"
    fi
    if [ -z "${OVPN_PORT:-}" ]; then
        OVPN_PORT="$(awk '$1=="remote" {print $3; exit}' "$ovpn_file" 2>/dev/null || true)"
    fi
    if [ -z "${OVPN_TRANSPORT:-}" ] || [ -z "${OVPN_FAMILY:-}" ]; then
        ovpn_proto_saved="$(awk '$1=="proto" {print $2; exit}' "$ovpn_file" 2>/dev/null || true)"
        case "$ovpn_proto_saved" in
            udp4) OVPN_TRANSPORT='udp'; OVPN_FAMILY='ipv4' ;;
            udp6) OVPN_TRANSPORT='udp'; OVPN_FAMILY='ipv6' ;;
            tcp4-client) OVPN_TRANSPORT='tcp'; OVPN_FAMILY='ipv4' ;;
            tcp6-client) OVPN_TRANSPORT='tcp'; OVPN_FAMILY='ipv6' ;;
        esac
    fi
    [ -n "${OVPN_CIPHER:-}" ] || OVPN_CIPHER="$(awk '$1=="cipher" {print $2; exit}' "$ovpn_file" 2>/dev/null || true)"
    [ -n "${OVPN_MTU:-}" ] || OVPN_MTU="$(awk '$1=="tun-mtu" {print $2; exit}' "$ovpn_file" 2>/dev/null || true)"
    [ -n "${OVPN_AUTH_DIGEST:-}" ] || OVPN_AUTH_DIGEST="$(awk '$1=="auth" {print $2; exit}' "$ovpn_file" 2>/dev/null || true)"
    [ -n "${OVPN_LZO:-}" ] || { grep -q '^comp-lzo yes$' "$ovpn_file" 2>/dev/null && OVPN_LZO='y' || OVPN_LZO='n'; }

    if [ -z "${OVPN_AUTH_MODE:-}" ]; then
        has_auth='0'; has_cert='0'
        grep -q '^auth-user-pass ' "$ovpn_file" 2>/dev/null && has_auth='1'
        grep -q '^<cert>$' "$ovpn_file" 2>/dev/null && has_cert='1'
        if [ "$has_auth" = '1' ] && [ "$has_cert" = '1' ]; then
            OVPN_AUTH_MODE='3'
        elif [ "$has_auth" = '1' ]; then
            OVPN_AUTH_MODE='1'
        elif [ "$has_cert" = '1' ]; then
            OVPN_AUTH_MODE='2'
        fi
    fi

    [ -n "${OVPN_TLS_MODE:-}" ] || {
        grep -q '^<tls-auth>$' "$ovpn_file" 2>/dev/null && OVPN_TLS_MODE='auth'
        grep -q '^<tls-crypt>$' "$ovpn_file" 2>/dev/null && OVPN_TLS_MODE='crypt'
        [ -n "${OVPN_TLS_MODE:-}" ] || OVPN_TLS_MODE='n'
    }

    [ -n "${OVPN_SERVER_VERIFY:-}" ] || {
        grep -q '^remote-cert-tls server$' "$ovpn_file" 2>/dev/null && OVPN_SERVER_VERIFY='2' || OVPN_SERVER_VERIFY='1'
    }

    [ -n "${OVPN_VERIFY_CN:-}" ] || {
        if grep -q '^verify-x509-name ' "$ovpn_file" 2>/dev/null; then
            OVPN_VERIFY_CN='y'
            [ -n "${OVPN_SERVER_CN:-}" ] || OVPN_SERVER_CN="$(awk '/^verify-x509-name /{sub(/^verify-x509-name /,""); sub(/ name$/,""); print; exit}' "$ovpn_file" 2>/dev/null || true)"
        else
            OVPN_VERIFY_CN='n'
        fi
    }

    if [ -z "${OVPN_USER:-}" ] && [ -f /etc/openvpn/auth.txt ]; then
        OVPN_USER="$(sed -n '1p' /etc/openvpn/auth.txt 2>/dev/null || true)"
    fi
}

extract_inline_block_to_file() {
    ovpn_file="$1"
    tag_name="$2"
    out_file="$3"

    awk -v tag="$tag_name" '
        $0 == "<" tag ">" { inblock = 1; next }
        $0 == "</" tag ">" { exit }
        inblock { print }
    ' "$ovpn_file" > "$out_file" 2>/dev/null || true
    [ -s "$out_file" ] || rm -f "$out_file"
}

derive_supernet16_from_cidr() {
    cidr="$1"
    printf '%s' "$cidr" | awk -F'[./]' '
        NF == 5 {
            print $1 "." $2 ".0.0/16"
            exit 0
        }
        { exit 1 }
    '
}

normalize_ipv4_cidr() {
    cidr="$1"
    printf '%s' "$cidr" | awk -F'[./]' '
        NF == 5 {
            a=$1; b=$2; c=$3; d=$4; m=$5;
            if (m < 0 || m > 32) exit 1;
            if (m >= 24) {
                if (m == 24) d = 0;
                print a "." b "." c "." d "/" m;
            }
            else if (m >= 16) {
                c = 0; d = 0;
                print a "." b "." c "." d "/" m;
            }
            else if (m >= 8) {
                b = 0; c = 0; d = 0;
                print a "." b "." c "." d "/" m;
            }
            else {
                a = 0; b = 0; c = 0; d = 0;
                print a "." b "." c "." d "/" m;
            }
            exit 0;
        }
        { exit 1 }
    '
}

normalize_ipv4_host() {
    host="$1"
    printf '%s' "$host" | awk -F. '
        NF == 4 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1;
            }
            print $1 "." $2 "." $3 "." $4;
            exit 0;
        }
        { exit 1 }
    '
}

infer_map_target_kind() {
    target="$1"
    case "$target" in
        */32) printf 'host\n' ;;
        */*) printf 'subnet\n' ;;
        *) printf 'host\n' ;;
    esac
}

parse_map_target() {
    target="$1"
    case "$target" in
        */*)
            target_norm="$(normalize_ipv4_cidr "$target" 2>/dev/null || true)"
            [ -n "$target_norm" ] || return 1
            target_host="${target%/*}"
            target_host_norm="$(normalize_ipv4_host "$target_host" 2>/dev/null || true)"
            [ -n "$target_host_norm" ] || return 1
            if [ "$target_norm" = "$target_host_norm/32" ]; then
                printf 'host|%s\n' "$target_host_norm"
            elif [ "$target_norm" = "$target" ]; then
                printf 'subnet|%s\n' "$target_norm"
            else
                printf 'host|%s\n' "$target_host_norm"
            fi
            ;;
        *)
            target_host_norm="$(normalize_ipv4_host "$target" 2>/dev/null || true)"
            [ -n "$target_host_norm" ] || return 1
            printf 'host|%s\n' "$target_host_norm"
            ;;
    esac
}

ensure_openvpn_profile_safety_flags() {
    ovpn_file="$1"
    [ -f "$ovpn_file" ] || return 0
    grep -q '^route-noexec$' "$ovpn_file" 2>/dev/null || printf '%s\n' 'route-noexec' >> "$ovpn_file"
}

validate_client_certificate_if_possible() {
    cert_file="$1"
    command -v openssl >/dev/null 2>&1 || return 0

    cert_subject="$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null || true)"
    [ -n "$cert_subject" ] || return 0

    case "$cert_subject" in
        *Server*|*server*)
            die "client certificate validate failed: this certificate subject looks like a server certificate ($cert_subject)"
            ;;
        *CA*|*Device\ CA*)
            die "client certificate validate failed: this certificate subject looks like a CA certificate ($cert_subject)"
            ;;
    esac
}

validate_client_cert_key_match_if_possible() {
    cert_file="$1"
    key_file="$2"
    command -v openssl >/dev/null 2>&1 || return 0

    cert_hash="$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$key_file" -pubout -outform der 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')"

    [ -n "$cert_hash" ] && [ -n "$key_hash" ] || return 0
    [ "$cert_hash" = "$key_hash" ] || die "client key validate failed: private key does not match client certificate"
}

fix_openclash_luci_compat() {
    oc_overwrite="/usr/lib/lua/luci/model/cbi/openclash/config-overwrite.lua"
    [ -f "$oc_overwrite" ] || return 0

    if grep -q 'datatype.cidr4(value)' "$oc_overwrite"; then
        backup_file "$oc_overwrite"
        sed -i 's/if datatype.cidr4(value) then/if ((datatype.cidr4 and datatype.cidr4(value)) or (datatype.ipmask4 and datatype.ipmask4(value))) then/' "$oc_overwrite"
    fi
}

write_openclash_switch_dashboard_template() {
    mkdir -p /usr/lib/lua/luci/view/openclash
    backup_file /usr/lib/lua/luci/view/openclash/switch_dashboard.htm

    cat > /usr/lib/lua/luci/view/openclash/switch_dashboard.htm <<'EOF'
<%+cbi/valueheader%>
<style type="text/css">
.cbi-value-field #switch_dashboard_Dashboard input[type="button"],
.cbi-value-field #switch_dashboard_Yacd input[type="button"],
.cbi-value-field #switch_dashboard_Metacubexd input[type="button"],
.cbi-value-field #switch_dashboard_Zashboard input[type="button"],
.cbi-value-field #delete_dashboard_Dashboard input[type="button"],
.cbi-value-field #delete_dashboard_Yacd input[type="button"],
.cbi-value-field #delete_dashboard_Metacubexd input[type="button"],
.cbi-value-field #delete_dashboard_Zashboard input[type="button"],
.cbi-value-field #default_dashboard_Dashboard input[type="button"],
.cbi-value-field #default_dashboard_Yacd input[type="button"],
.cbi-value-field #default_dashboard_Metacubexd input[type="button"],
.cbi-value-field #default_dashboard_Zashboard input[type="button"] {
	display: inline-block !important;
	min-width: 210px !important;
	padding: 6px 14px !important;
	margin: 0 8px 6px 0 !important;
	border: 1px solid #3b82f6 !important;
	border-radius: 8px !important;
	background: #ffffff !important;
	color: #1f2937 !important;
	font-weight: 600 !important;
	box-shadow: 0 1px 2px rgba(0,0,0,.08) !important;
	cursor: pointer !important;
}
</style>
<%
local uci = require "luci.model.uci".cursor()
local dashboard_type = uci:get("openclash", "config", "dashboard_type") or "Official"
local yacd_type = uci:get("openclash", "config", "yacd_type") or "Official"
local option_name = self.option or ""
local switch_title = ""
local switch_target = ""

if option_name == "Dashboard" then
    switch_title = dashboard_type == "Meta" and "Switch To Official Version" or "Switch To Meta Version"
    switch_target = dashboard_type == "Meta" and "Official" or "Meta"
elseif option_name == "Yacd" then
    switch_title = yacd_type == "Meta" and "Switch To Official Version" or "Switch To Meta Version"
    switch_target = yacd_type == "Meta" and "Official" or "Meta"
elseif option_name == "Metacubexd" then
    switch_title = "Update Metacubexd Version"
    switch_target = "Official"
elseif option_name == "Zashboard" then
    switch_title = "Update Zashboard Version"
    switch_target = "Official"
end
%>
<div class="cbi-value-field" id="switch_dashboard_<%=self.option%>">
	<% if switch_title ~= "" then %>
	<input type="button" class="btn cbi-button cbi-button-reset" value="<%=switch_title%>" onclick="return switch_dashboard(this, '<%=option_name%>', '<%=switch_target%>')"/>
	<% else %>
	<%:Collecting data...%>
	<% end %>
</div>
<div class="cbi-value-field" id="delete_dashboard_<%=self.option%>">
	<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Delete%>" onclick="return delete_dashboard(this, '<%=self.option%>')"/>
</div>
<div class="cbi-value-field" id="default_dashboard_<%=self.option%>">
	<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Set to Default%>" onclick="return default_dashboard(this, '<%=self.option%>')"/>
</div>

<script type="text/javascript">//<![CDATA[
	var btn_type_<%=self.option%> = "<%=self.option%>";
	var switch_dashboard_<%=self.option%> = document.getElementById('switch_dashboard_<%=self.option%>');
	var default_dashboard_<%=self.option%> = document.getElementById('default_dashboard_<%=self.option%>');
	var delete_dashboard_<%=self.option%> = document.getElementById('delete_dashboard_<%=self.option%>');
	XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "dashboard_type")%>', null, function(x, status) {
	      	if ( x && x.status == 200 ) {
			if ( btn_type_<%=self.option%> == "Dashboard" ) {
				if ( status.dashboard_type == "Meta" ) {
					switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Official Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Official\')"/>';
				}
				else {
					switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Meta Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Meta\')"/>';
				}
			}
			if ( btn_type_<%=self.option%> == "Yacd" ) {
				if ( status.yacd_type == "Meta" ) {
					switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Official Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Official\')"/>';
				}
				else {
					switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Meta Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Meta\')"/>';
				}
			}
			if ( btn_type_<%=self.option%> == "Metacubexd" ) {
				switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Metacubexd Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Official\')"/>';
			}
	      	if ( btn_type_<%=self.option%> == "Zashboard" ) {
				switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Zashboard Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \'Official\')"/>';
			}

			if ( status.default_dashboard == btn_type_<%=self.option%>.toLowerCase() ) {
				default_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Default%>" disabled="disabled" onclick="return default_dashboard(this, btn_type_<%=self.option%>)"/>';
			}

			if ( !status[btn_type_<%=self.option%>.toLowerCase()] ) {
				default_dashboard_<%=self.option%>.firstElementChild.disabled = true;
				delete_dashboard_<%=self.option%>.firstElementChild.disabled = true;
			}
	        }
		});

	function switch_dashboard(btn, name, type)
	{
		btn.disabled = true;
		btn.value = '<%:Downloading File...%>';
		XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "switch_dashboard")%>', {name: name, type : type}, function(x, status) {
			if ( x && x.status == 200 ) {
				if ( status.download_state == "0" ) {
					if ( type == "Meta" ) {
						if ( name == "Dashboard" ) {
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch Successful%> - <%:Switch To Official Version%>" onclick="return switch_dashboard(this, \'Dashboard\', \'Official\')"/>';
						}
						else
						{
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch Successful%> - <%:Switch To Official Version%>" onclick="return switch_dashboard(this, \'Yacd\', \'Official\')"/>';
						}
					}
					else {
						if ( name == "Dashboard" ) {
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch Successful%> - <%:Switch To Meta Version%>" onclick="return switch_dashboard(this, \'Dashboard\', \'Meta\')"/>';
						}
						else if ( name == "Yacd" ) 
						{
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch Successful%> - <%:Switch To Meta Version%>" onclick="return switch_dashboard(this, \'Yacd\', \'Meta\')"/>';
						}
						else if ( name == "Metacubexd" ) {
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Successful%> - <%:Update Metacubexd Version%>" onclick="return switch_dashboard(this, \'Metacubexd\', \'Official\')"/>';
						} else {
							document.getElementById("switch_dashboard_"+name).innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Successful%> - <%:Update Zashboard Version%>" onclick="return switch_dashboard(this, \'Zashboard\', \'Official\')"/>';
	            		}
					}
					document.getElementById("default_dashboard_"+name).firstElementChild.disabled = false;
					document.getElementById("delete_dashboard_"+name).firstElementChild.disabled = false;
				}
				else if ( status.download_state == "2" ) {
					btn.value = '<%:Unzip Error%>';
				}
				else {
					if ( name == "Metacubexd" || name == "Zashboard" ) {
						btn.value = '<%:Update Failed%>';
					}
					else {
						btn.value = '<%:Switch Failed%>';
					}
				}
			}
		});
		btn.disabled = false;
		return false; 
	}

	function delete_dashboard(btn, name)
	{
		if ( confirm("<%:Are you sure you want to delete this panel?%>") ) {
			btn.disabled = true;
			XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "delete_dashboard")%>', {name: name}, function(x, status) {
				if ( x && x.status == 200 ) {
					if ( status.delete_state == "1" ) {
						if ( document.getElementById('default_dashboard_' + name).firstElementChild.disabled ) {
							document.getElementById('default_dashboard_' + name).firstElementChild.value = '<%:Set to Default%>';
						}
						document.getElementById('default_dashboard_' + name).firstElementChild.disabled = true;
					}
					else {
						btn.disabled = false;
					}
				}
			});
		}
		return false; 
	}

	function default_dashboard(btn, name)
	{
		btn.disabled = true;
		XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "default_dashboard")%>', {name: name}, function(x, status) {
			if ( x && x.status == 200 ) {
				btn.value = '<%:Default%>';
				btn.disabled = true;
				var allBtns = document.querySelectorAll('[id^="default_dashboard_"]');
				for (var i = 0; i < allBtns.length; i++) {
					var btnEl = allBtns[i].firstElementChild;
					if (btnEl && btnEl !== btn && btnEl.value === '<%:Default%>') {
						btnEl.disabled = false;
						btnEl.value = '<%:Set to Default%>';
					}
				}
			} else {
				btn.disabled = false;
			}
		});
		return false;
	}

//]]></script>

<%+cbi/valuefooter%>
EOF
}

patch_openclash_dashboard_settings() {
    settings="/usr/lib/lua/luci/model/cbi/openclash/settings.lua"
    [ -f "$settings" ] || return 0

    if ! grep -q 'o.rawhtml = true' "$settings"; then
        backup_file "$settings"
        sed -i '/o.template="openclash\/switch_dashboard"/a\	o.rawhtml = true' "$settings"
    fi
}

patch_openclash_cidr6_compat() {
    settings="/usr/lib/lua/luci/model/cbi/openclash/settings.lua"
    [ -f "$settings" ] || return 0
    grep -q 'datatype.cidr6(value)' "$settings" || return 0
    grep -q 'datatype.cidr6 or datatype.ipmask6' "$settings" && return 0

    backup_file "$settings"
    sed -i 's/datatype\.cidr6(value)/(datatype.cidr6 or datatype.ipmask6)(value)/' "$settings"
}

install_openclash() {
    [ -f "$CFG" ] || die "appcenter config not found: $CFG"
    [ -f "$TPL" ] || die "appcenter template not found: $TPL"

    mkdir -p "$WORKDIR/openclash/pkg" "$WORKDIR/openclash/control"
    version_file="$WORKDIR/openclash/version"
    raw_ipk="$WORKDIR/openclash/openclash.ipk"
    fixed_ipk="$WORKDIR/openclash/openclash-fixed.ipk"

    log "tip: downloading OpenClash version file..."
    mirror_base="$(download_from_mirrors "version" "$version_file")" || die "failed to fetch OpenClash version from all mirrors"
    last_ver="$(sed -n '1p' "$version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$last_ver" ] || die "failed to parse OpenClash version"

    log "tip: downloading OpenClash v$last_ver..."
    download_file "$mirror_base/luci-app-openclash_${last_ver}_all.ipk" "$raw_ipk" || die "OpenClash package download failed"
    [ -s "$raw_ipk" ] || die "OpenClash package download failed"
    oc_download_size="$(wc -c < "$raw_ipk" | tr -d ' ')"
    log "downloaded: OpenClash v$last_ver ($oc_download_size bytes)"
    log "next step will modify system files: /etc/config/appcenter and $TPL"
    confirm_or_exit "确认继续安装 OpenClash 并修改系统吗？"

    ensure_opkg_update
    ensure_packages dnsmasq-full bash curl ca-bundle ip-full ruby ruby-yaml kmod-inet-diag kmod-nft-tproxy kmod-tun unzip

    extract_ipk_archive "$raw_ipk" "$WORKDIR/openclash/pkg"
    [ -f "$WORKDIR/openclash/pkg/control.tar.gz" ] || die "OpenClash package missing control.tar.gz"
    [ -f "$WORKDIR/openclash/pkg/data.tar.gz" ] || die "OpenClash package missing data.tar.gz"
    [ -f "$WORKDIR/openclash/pkg/debian-binary" ] || die "OpenClash package missing debian-binary"
    tar -xzf "$WORKDIR/openclash/pkg/control.tar.gz" -C "$WORKDIR/openclash/control"
    sed -i \
        -e 's/, *luci-compat//g' \
        -e 's/luci-compat, *//g' \
        -e 's/luci-compat//g' \
        "$WORKDIR/openclash/control/control"
    tar -czf "$WORKDIR/openclash/pkg/control.tar.gz" -C "$WORKDIR/openclash/control" .
    (cd "$WORKDIR/openclash/pkg" && tar -czf "$fixed_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
    [ -s "$fixed_ipk" ] || die "failed to rebuild OpenClash package"

    backup_file "$CFG"
    if ! opkg install "$fixed_ipk" --force-reinstall >/tmp/openclash-install.log 2>&1; then
        if ! opkg install "$fixed_ipk" --force-reinstall --force-depends --force-maintainer >/tmp/openclash-install.log 2>&1; then
            sed -n '1,200p' /tmp/openclash-install.log >&2
            die "OpenClash install failed"
        fi
    fi

    oc_ver="$(opkg status luci-app-openclash 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$oc_ver" ] || oc_ver="$last_ver"
    oc_size="$(wc -c < "$fixed_ipk" | tr -d ' ')"

    set_appcenter_entry "luci-app-openclash" "luci-app-openclash" "$oc_ver" "$oc_size" "/usr/lib/lua/luci/controller/openclash.lua" "admin/services/openclash"
    uci commit appcenter

    fix_openclash_luci_compat
    write_openclash_switch_dashboard_template
    patch_openclash_dashboard_settings
    patch_openclash_cidr6_compat
    patch_common_template
    refresh_luci_appcenter
    ensure_plugin_autostart_order
    ensure_swapfile_boot
    reduce_openclash_memory_pressure
    verify_appcenter_route "luci-app-openclash" "admin/services/openclash"
    verify_file_exists /usr/lib/lua/luci/controller/openclash.lua "OpenClash"
    verify_luci_route admin/services/openclash "OpenClash"
    verify_luci_route admin/services/openclash/settings "OpenClash"
    verify_luci_route admin/services/openclash/config-overwrite "OpenClash"
    verify_luci_route admin/services/openclash/config-subscribe "OpenClash"
    verify_luci_route admin/services/openclash/config "OpenClash"
    verify_luci_route admin/services/openclash/log "OpenClash"

    smart_core_downloaded='0'
    if confirm_default_yes "是否现在下载 OpenClash smart 核心？"; then
        install_openclash_smart_core
        smart_core_downloaded='1'
        verify_file_exists /etc/openclash/core/clash_meta "OpenClash smart core"
        verify_file_exists /etc/openclash/core/clash "OpenClash smart core"
        log "note:     smart core 已安装到 /etc/openclash/core"
    else
        log "note:     已跳过 smart core 下载"
    fi

    log "done"
    log "plugin:   OpenClash"
    log "version:  $oc_ver"
    log "route:    admin/services/openclash"
    if [ "$smart_core_downloaded" = '1' ]; then
        log "core:     OpenClash smart"
        log "core-ver: $smart_core_ver"
        log "core-path: /etc/openclash/core"
    else
        log "core:     not downloaded"
    fi
    log "next:     close appcenter popup, then press Ctrl+F5 and reopen OpenClash"
}

write_adguard_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/AdGuardHome
    cat > /usr/lib/lua/luci/controller/AdGuardHome.lua <<'EOF'
module("luci.controller.AdGuardHome",package.seeall)
local fs=require"nixio.fs"
local http=require"luci.http"
local sys=require"luci.sys"
local uci=require"luci.model.uci".cursor()
function index()
entry({"admin", "services", "AdGuardHome"},alias("admin", "services", "AdGuardHome", "oem"),_("AdGuard Home"), 10).dependent = true
entry({"admin","services","AdGuardHome","oem"},template("AdGuardHome/oem_wrapper"),_("Overview"),0).leaf = true
entry({"admin","services","AdGuardHome","base"},cbi("AdGuardHome/base"),_("Base Setting"),1).leaf = true
entry({"admin","services","AdGuardHome","log"},form("AdGuardHome/log"),_("Log"),2).leaf = true
entry({"admin","services","AdGuardHome","manual"},cbi("AdGuardHome/manual"),_("Manual Config"),3).leaf = true
entry({"admin", "services", "AdGuardHome", "status"},call("act_status")).leaf=true
entry({"admin", "services", "AdGuardHome", "check"}, call("check_update"))
entry({"admin", "services", "AdGuardHome", "doupdate"}, call("do_update"))
entry({"admin", "services", "AdGuardHome", "getlog"}, call("get_log"))
entry({"admin", "services", "AdGuardHome", "dodellog"}, call("do_dellog"))
entry({"admin", "services", "AdGuardHome", "reloadconfig"}, call("reload_config"))
entry({"admin", "services", "AdGuardHome", "gettemplateconfig"}, call("get_template_config"))
end
function get_template_config()
local b
local d=""
local rf=io.open("/tmp/resolv.conf.auto", "r")
if rf then
local lan_ip = uci:get("network", "lan", "ipaddr") or ""
for cnt in rf:lines() do
b=string.match (cnt,"^[^#]*nameserver%s+([^%s]+)$")
if (b~=nil) and not b:match("^127%.") and b ~= "0.0.0.0" and b ~= "::1" and b ~= lan_ip then
d=d.."  - "..b.."\n"
end
end
rf:close()
end
local f=io.open("/usr/share/AdGuardHome/AdGuardHome_template.yaml", "r+")
if not f then
http.prepare_content("text/plain; charset=utf-8")
http.write("")
return
end
local tbl = {}
local a=""
while (1) do
a=f:read("*l")
if (a=="#bootstrap_dns") then
a=d
elseif (a=="#upstream_dns") then
a=d
elseif (a==nil) then
break
end
table.insert(tbl, a)
end
f:close()
http.prepare_content("text/plain; charset=utf-8")
http.write(table.concat(tbl, "\n"))
end
function reload_config()
fs.remove("/tmp/AdGuardHometmpconfig.yaml")
http.prepare_content("application/json")
http.write('')
end
function act_status()
local e={}
local binpath=uci:get("AdGuardHome","AdGuardHome","binpath")
    e.running=sys.call("pgrep "..binpath.." >/dev/null")==0
e.redirect=(fs.readfile("/var/run/AdGredir")=="1")
http.prepare_content("application/json")
http.write_json(e)
end
function do_update()
fs.writefile("/var/run/lucilogpos","0")
http.prepare_content("application/json")
http.write('')
local arg
if luci.http.formvalue("force") == "1" then
arg="force"
else
arg=""
end
if fs.access("/var/run/update_core") then
if arg=="force" then
    sys.exec("kill $(pgrep /usr/share/AdGuardHome/update_core.sh) ; sh /usr/share/AdGuardHome/update_core.sh "..arg.." >/tmp/AdGuardHome_update.log 2>&1 &")
end
else
    sys.exec("sh /usr/share/AdGuardHome/update_core.sh "..arg.." >/tmp/AdGuardHome_update.log 2>&1 &")
end
end
function get_log()
local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
if (logfile==nil) then
http.write("no log available\n")
return
end
local data=fs.readfile(logfile)
if (data) then
http.write(data)
else
http.write("can't open log file\n")
end
end
function do_dellog()
local logfile=uci:get("AdGuardHome","AdGuardHome","logfile")
if (logfile) then
fs.writefile(logfile,"")
end
http.prepare_content("application/json")
http.write('')
end
function check_update()
local e={}
    local pkg_ver=sys.exec("grep PKG_VERSION /usr/share/AdGuardHome/Makefile 2>/dev/null | awk -F := '{print $2}'")
e.luciversion=string.sub(pkg_ver,1,-2)
e.coreversion=uci:get("AdGuardHome","AdGuardHome","coreversion") or ""
http.prepare_content("application/json")
http.write_json(e)
end
EOF

    cat > /usr/lib/lua/luci/view/AdGuardHome/oem_wrapper.htm <<'EOF'
<%
local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local base_url = dispatcher.build_url("admin", "services", "AdGuardHome")
local tab = http.formvalue("tab") or "base"
if tab ~= "base" and tab ~= "manual" and tab ~= "log" then
    tab = "base"
end
local frame_url = base_url .. "/" .. tab
%>
<%+header%>
<style>
    .adg-wrap { margin-bottom: 20px; }
    .adg-tabs { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 16px; }
    .adg-tab { display: inline-block; padding: 8px 14px; border-bottom: 2px solid transparent; color: #666; cursor: pointer; }
    .adg-tab.active { color: #0088cc; border-bottom-color: #0088cc; }
    .adg-frame { width: 100%; min-height: 760px; border: 0; background: #fff; }
</style>
<div class="cbi-map adg-wrap">
    <h2 name="content">AdGuard Home</h2>
    <div class="cbi-map-descr">OEM compatibility wrapper for AdGuard Home pages.</div>
    <div class="adg-tabs">
        <a class="adg-tab<%= tab == 'base' and ' active' or '' %>" data-tab="base" href="<%=base_url%>?tab=base">Base Setting</a>
        <a class="adg-tab<%= tab == 'manual' and ' active' or '' %>" data-tab="manual" href="<%=base_url%>?tab=manual">Manual Config</a>
        <a class="adg-tab<%= tab == 'log' and ' active' or '' %>" data-tab="log" href="<%=base_url%>?tab=log">Log</a>
    </div>
    <iframe id="adg_frame" class="adg-frame" name="adg_frame" src="<%=frame_url%>" onload="adgAfterLoad()"></iframe>
</div>
<script>
function adgResizeFrame() {
    var frame = document.getElementById('adg_frame');
    if (!frame) return;
    try {
        var d = frame.contentWindow.document;
        var h1 = d.body ? d.body.scrollHeight : 0;
        var h2 = d.documentElement ? d.documentElement.scrollHeight : 0;
        var height = Math.max(h1, h2, 760);
        frame.style.height = height + 'px';
    } catch (e) {}
}
function adgHideInnerChrome() {
    var frame = document.getElementById('adg_frame');
    if (!frame) return;
    try {
        var d = frame.contentWindow.document;
        var hideSelectors = ['header', '.menu_mobile', '.mobile_bg_color.container.body-container.visible-xs-block', '.footer', '.tail_wave'];
        for (var i = 0; i < hideSelectors.length; i++) {
            var nodes = d.querySelectorAll(hideSelectors[i]);
            for (var j = 0; j < nodes.length; j++) nodes[j].style.display = 'none';
        }
        var containers = d.querySelectorAll('.container.body-container');
        for (var k = 0; k < containers.length; k++) {
            if (!containers[k].classList.contains('visible-xs-block')) {
                containers[k].style.width = '100%';
                containers[k].style.margin = '0';
                containers[k].style.padding = '0 10px';
            }
        }
        var main = d.querySelector('.main');
        if (main) { main.style.width = '100%'; main.style.margin = '0'; }
        var content = d.querySelector('.main-content');
        if (content) { content.style.width = '100%'; content.style.margin = '0'; content.style.padding = '0'; }
        if (d.body) { d.body.style.marginTop = '0'; d.body.style.paddingTop = '0'; }
    } catch (e) {}
}
function adgAfterLoad() {
    adgHideInnerChrome();
    adgResizeFrame();
    setTimeout(function() { adgHideInnerChrome(); adgResizeFrame(); }, 300);
}
</script>
<%+footer%>
EOF
}

patch_adguard_enable_hook() {
    base_lua="/usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua"
    [ -f "$base_lua" ] || return 0
    grep -q '/etc/init.d/AdGuardHome enable >/dev/null 2>&1; /etc/init.d/AdGuardHome restart >/dev/null 2>&1 &' "$base_lua" 2>/dev/null && return 0

    backup_file "$base_lua"
    mkdir -p "$WORKDIR/adguardhome"
    tmp_file="$WORKDIR/adguardhome/base.lua"
    awk '
        BEGIN { in_hook = 0 }
        /^function m\.on_commit\(map\)$/ {
            in_hook = 1
            print "function m.on_commit(map)"
            print "\tlocal enabled=uci:get(\"AdGuardHome\",\"AdGuardHome\",\"enabled\")"
            print "\tif enabled==\"1\" then"
            print "\t\tio.popen(\"/etc/init.d/AdGuardHome enable >/dev/null 2>&1; /etc/init.d/AdGuardHome restart >/dev/null 2>&1 &\")"
            print "\telse"
            print "\t\tio.popen(\"/etc/init.d/AdGuardHome disable >/dev/null 2>&1; /etc/init.d/AdGuardHome stop >/dev/null 2>&1 &\")"
            print "\tend"
            next
        }
        in_hook {
            if ($0 ~ /^return m$/) {
                in_hook = 0
                print "end"
                print
            }
            next
        }
        { print }
    ' "$base_lua" > "$tmp_file" && mv "$tmp_file" "$base_lua"
}

fix_adguard_runtime_if_possible() {
    binpath="$(uci -q get AdGuardHome.AdGuardHome.binpath 2>/dev/null || true)"
    [ -n "$binpath" ] || binpath="/usr/bin/AdGuardHome/AdGuardHome"
    [ -x "$binpath" ] || return 0

    configpath="$(uci -q get AdGuardHome.AdGuardHome.configpath 2>/dev/null || true)"
    [ -n "$configpath" ] || configpath="/etc/AdGuardHome.yaml"
    workdir="$(uci -q get AdGuardHome.AdGuardHome.workdir 2>/dev/null || true)"
    [ -n "$workdir" ] || workdir="/usr/bin/AdGuardHome"
    template_yaml="/usr/share/AdGuardHome/AdGuardHome_template.yaml"

    ensure_adguard_session_ttl() {
        yaml_file="$1"
        [ -f "$yaml_file" ] || return 0

        if grep -q '^  session_ttl: ' "$yaml_file" 2>/dev/null; then
            sed -i 's/^  session_ttl: .*/  session_ttl: 720h/' "$yaml_file"
        elif grep -q '^bind_port:' "$yaml_file" 2>/dev/null; then
            awk '
                {
                    print
                    if (!done && $0 ~ /^bind_port:/) {
                        print "session_ttl: 720h"
                        done = 1
                    }
                }
            ' "$yaml_file" > "$yaml_file.tmp" && mv "$yaml_file.tmp" "$yaml_file"
        fi
    }

    if [ ! -s "$configpath" ] && [ -f "$template_yaml" ]; then
        mkdir -p "${configpath%/*}" "$workdir/data"
        lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
        dns_list="$(awk -v lan_ip="$lan_ip" '/^[^#]*nameserver[[:space:]]+/ { ip=$2; if (ip ~ /^127\./ || ip == "0.0.0.0" || ip == "::1" || ip == lan_ip) next; print "  - " ip }' /tmp/resolv.conf.auto 2>/dev/null || true)"
        [ -n "$dns_list" ] || dns_list="$(printf '  - 223.5.5.5\n  - 119.29.29.29\n')"
        awk -v dns="$dns_list" '
            /^#bootstrap_dns$/ { print dns; next }
            /^#upstream_dns$/ { print dns; next }
            { print }
        ' "$template_yaml" > "$configpath"
    fi

    ensure_adguard_session_ttl "$template_yaml"
    ensure_adguard_session_ttl "$configpath"

    [ -s "$configpath" ] && "$binpath" -c "$configpath" --check-config >/tmp/AdGuardHometest.log 2>&1 || true
}

get_adguardhome_core_arch() {
    machine="$(uname -m 2>/dev/null || true)"

    case "$machine" in
        x86_64) printf '%s\n' amd64 ;;
        i386|i686) printf '%s\n' 386 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        armv7l|armv7) printf '%s\n' armv7 ;;
        armv6l|armv6) printf '%s\n' armv6 ;;
        armv5tel|armv5*) printf '%s\n' armv5 ;;
        mips64el|mips64le) printf '%s\n' mips64le ;;
        mips64) printf '%s\n' mips64 ;;
        mipsel|mipsle)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mipsle-softfloat
            else
                printf '%s\n' mipsle-hardfloat
            fi
            ;;
        mips)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mips-softfloat
            else
                printf '%s\n' mips-hardfloat
            fi
            ;;
        ppc64le) printf '%s\n' ppc64le ;;
        riscv64) printf '%s\n' riscv64 ;;
        *) return 1 ;;
    esac
}

download_adguardhome_core() {
    core_arch="$(get_adguardhome_core_arch 2>/dev/null || true)"
    [ -n "$core_arch" ] || die "failed to detect AdGuardHome core architecture"

    mkdir -p "$WORKDIR/adguardhome/core" /usr/bin/AdGuardHome
    core_tar="$WORKDIR/adguardhome/AdGuardHome_linux_${core_arch}.tar.gz"
    core_unpack="$WORKDIR/adguardhome/core"
    core_bin="/usr/bin/AdGuardHome/AdGuardHome"

    log "tip: downloading AdGuardHome core via CDN..."
    download_from_mirrors "AdGuardHome_linux_${core_arch}.tar.gz" "$core_tar" "$ADGUARDHOME_CORE_MIRRORS" || die "failed to download AdGuardHome core from CDN mirrors"
    [ -s "$core_tar" ] || die "AdGuardHome core download failed"

    for existing in "$core_bin"; do
        [ -f "$existing" ] && backup_file "$existing"
    done

    tar -xzf "$core_tar" -C "$core_unpack" >/dev/null 2>&1 || die "failed to extract AdGuardHome core"

    core_src=""
    for candidate in "$core_unpack"/AdGuardHome "$core_unpack"/*/AdGuardHome "$core_unpack"/*/*/AdGuardHome; do
        [ -f "$candidate" ] || continue
        core_src="$candidate"
        break
    done
    [ -n "$core_src" ] || die "failed to locate extracted AdGuardHome core binary"

    cp "$core_src" "$core_bin"
    chmod 755 "$core_bin" 2>/dev/null || true
    uci set AdGuardHome.AdGuardHome.coreversion='latest' >/dev/null 2>&1 || true
    uci commit AdGuardHome >/dev/null 2>&1 || true

    log "done"
    log "core:     AdGuardHome"
    log "version:  latest"
    log "arch:     $core_arch"
    log "path:     $core_bin"
}

set_init_start_order() {
    init_script="$1"
    start_order="$2"

    [ -f "$init_script" ] || return 0
    if ! grep -q "^START=$start_order$" "$init_script"; then
        backup_file "$init_script"
        sed -i "s/^START=.*/START=$start_order/" "$init_script"
    fi
}

ensure_plugin_autostart_order() {
    set_init_start_order /etc/init.d/openvpn 90
    set_init_start_order /etc/init.d/openclash 98
    set_init_start_order /etc/init.d/AdGuardHome 120
}

ensure_swapfile_boot() {
    local swapfile="/overlay/swapfile"
    [ -f "$swapfile" ] || return 0

    local sec
    sec="$(uci -q show fstab 2>/dev/null | awk -F'.|=' '/fstab\.@swap\[[0-9]+\]\.device=\x27\/overlay\/swapfile\x27/{print $2; exit}' )"
    if [ -z "$sec" ]; then
        sec="$(uci -q add fstab swap 2>/dev/null || true)"
    fi
    [ -n "$sec" ] || return 0
    uci -q set fstab."$sec".device='/overlay/swapfile' >/dev/null 2>&1 || true
    uci -q set fstab."$sec".enabled='1' >/dev/null 2>&1 || true
    uci -q set fstab."$sec".label='swapfile' >/dev/null 2>&1 || true
    uci -q commit fstab >/dev/null 2>&1 || true
}

reduce_openclash_memory_pressure() {
    [ -f /etc/config/openclash ] || return 0

    uci set openclash.config.smart_collect='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_meta_sniffer='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_meta_sniffer_pure_ip='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_meta_sniffer_custom='0' >/dev/null 2>&1 || true
    uci set openclash.config.smart_enable_lgbm='0' >/dev/null 2>&1 || true
    uci set openclash.config.auto_smart_switch='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_tcp_concurrent='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_unified_delay='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_custom_dns='0' >/dev/null 2>&1 || true
    uci set openclash.config.enable_respect_rules='0' >/dev/null 2>&1 || true
    uci commit openclash >/dev/null 2>&1 || true
}

fix_adguard_start_order() {
    set_init_start_order /etc/init.d/AdGuardHome 120
}

install_adguardhome() {
    [ -f "$CFG" ] || die "appcenter config not found: $CFG"
    [ -f "$TPL" ] || die "appcenter template not found: $TPL"

    mkdir -p "$WORKDIR/adguardhome"
    adg_ipk="$WORKDIR/adguardhome/luci-app-adguardhome.ipk"
    log "tip: downloading AdGuardHome official release via CDN..."
    adg_download_url="$(download_from_urls "$adg_ipk" $ADGUARDHOME_IPK_URLS)" || die "failed to download AdGuardHome ipk from all CDN mirrors"
    adg_download_size="$(wc -c < "$adg_ipk" | tr -d ' ')"
    log "downloaded: AdGuardHome $ADGUARDHOME_VERSION ($adg_download_size bytes)"
    log "next step will modify system files: /etc/config/appcenter, $TPL and AdGuardHome LuCI files"
    confirm_or_exit "确认继续安装 AdGuardHome 并修改系统吗？"
    install_ipk_file "$adg_ipk" "AdGuardHome"

    for needed in \
        /usr/lib/lua/luci/controller/AdGuardHome.lua \
        /usr/lib/lua/luci/model/cbi/AdGuardHome/base.lua \
        /usr/lib/lua/luci/model/cbi/AdGuardHome/manual.lua \
        /usr/lib/lua/luci/model/cbi/AdGuardHome/log.lua \
        /usr/share/AdGuardHome/AdGuardHome_template.yaml; do
        [ -f "$needed" ] || die "AdGuardHome install incomplete: missing $needed"
    done

    backup_file /usr/lib/lua/luci/controller/AdGuardHome.lua
    backup_file /usr/lib/lua/luci/view/AdGuardHome/oem_wrapper.htm

    write_adguard_wrapper_files
    patch_adguard_enable_hook
    fix_adguard_start_order

    adg_ver="$(opkg status luci-app-adguardhome 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$adg_ver" ] || adg_ver="$ADGUARDHOME_VERSION"
    adg_size="$(opkg status luci-app-adguardhome 2>/dev/null | awk -F': ' '/Installed-Size: /{print $2; exit}')"
    [ -n "$adg_size" ] || adg_size="91326"

    backup_file "$CFG"
    set_appcenter_entry "luci-app-adguardhome" "luci-app-adguardhome" "$adg_ver" "$adg_size" "/usr/lib/lua/luci/controller/AdGuardHome.lua" "admin/services/AdGuardHome"
    uci commit appcenter

    patch_common_template
    refresh_luci_appcenter
    ensure_plugin_autostart_order
    fix_adguard_runtime_if_possible
    verify_appcenter_route "luci-app-adguardhome" "admin/services/AdGuardHome"
    verify_file_exists /usr/lib/lua/luci/controller/AdGuardHome.lua "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/base "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/manual "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/log "AdGuardHome"

    adg_core_downloaded='0'
    if confirm_default_yes "是否现在下载 AdGuardHome 核心（CDN）？"; then
        download_adguardhome_core
        adg_core_downloaded='1'
        verify_file_exists /usr/bin/AdGuardHome/AdGuardHome "AdGuardHome core"
        fix_adguard_runtime_if_possible
    else
        log "note:     已跳过 AdGuardHome 核心下载"
    fi

    log "done"
    log "plugin:   AdGuardHome"
    log "version:  $adg_ver"
    log "route:    admin/services/AdGuardHome"
    if [ "$adg_core_downloaded" = '1' ]; then
        log "core:     AdGuardHome"
        log "core-ver: latest"
        log "core-path: /usr/bin/AdGuardHome/AdGuardHome"
    elif [ -x /usr/bin/AdGuardHome/AdGuardHome ]; then
        log "note:     core present; config/start checked"
    else
        log "note:     LuCI 已装好；核心请在 AdGuardHome 页面里更新后再启动"
    fi
    log "next:     close appcenter popup, then press Ctrl+F5 and reopen AdGuardHome"
}

write_openvpn_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller/nradio_adv /usr/lib/lua/luci/view/nradio_adv /usr/lib/lua/luci/view/openvpn

    cat > /usr/lib/lua/luci/controller/nradio_adv/openvpn_full.lua <<'EOF'
module("luci.controller.nradio_adv.openvpn_full", package.seeall)
local dispatcher = require "luci.dispatcher"
function index()
    local page = entry({"nradioadv", "system", "openvpnfull"}, template("nradio_adv/openvpn_full"), _("OpenVPN"), 94)
    page.show = true
    entry({"nradioadv", "system", "openvpnfull", "restart"}, call("restart"), nil).leaf = true
end
function restart()
    local http = require "luci.http"
    os.execute("( /etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn_client restart >/dev/null 2>&1 ) &")
    http.redirect(dispatcher.build_url("nradioadv", "system", "openvpnfull"))
end
EOF

    cat > /usr/lib/lua/luci/view/openvpn/ovpn_css.htm <<'EOF'
<style type="text/css">
    .vpn-shell {
        max-width: 1160px;
        margin: 0 auto;
    }
    .vpn-hero {
        position: relative;
        overflow: hidden;
        margin: 18px 0 16px;
        padding: 22px 24px;
        border: 1px solid #dbe5ee;
        border-radius: 18px;
        background: linear-gradient(135deg, #f4f8ff 0%, #ffffff 54%, #f8fafc 100%);
        box-shadow: 0 10px 28px rgba(15, 23, 42, 0.06);
    }
    .vpn-hero:before {
        content: "";
        position: absolute;
        right: -50px;
        top: -50px;
        width: 160px;
        height: 160px;
        border-radius: 999px;
        background: radial-gradient(circle, rgba(37, 99, 235, 0.16) 0%, rgba(37, 99, 235, 0) 72%);
    }
    .vpn-hero h2 {
        margin: 0 0 6px;
        font-size: 26px;
        line-height: 1.2;
        color: #0f172a;
    }
    .vpn-sub {
        margin: 0;
        color: #66707c;
        line-height: 1.7;
    }
    .vpn-hero-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-top: 16px;
    }
    .vpn-status-chip {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        padding: 4px 12px;
        border-radius: 999px;
        background: #dcfce7;
        color: #166534;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.02em;
    }
    .vpn-status-chip.off {
        background: #fee2e2;
        color: #991b1b;
    }
    .vpn-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(290px, 1fr));
        gap: 14px;
        margin-bottom: 18px;
    }
    .vpn-card {
        padding: 16px 18px;
        border: 1px solid #e7eaee;
        border-radius: 14px;
        background: #fff;
        box-shadow: 0 6px 16px rgba(15, 23, 42, 0.03);
    }
    .vpn-card-title {
        margin-bottom: 12px;
        font-size: 15px;
        font-weight: 700;
        color: #0f172a;
    }
    .vpn-kv {
        display: flex;
        justify-content: space-between;
        gap: 12px;
        padding: 9px 0;
        border-bottom: 1px solid #f1f3f5;
    }
    .vpn-kv:last-child {
        border-bottom: 0;
        padding-bottom: 0;
    }
    .vpn-kv span:first-child {
        color: #68707a;
    }
    .vpn-kv strong {
        color: #0f172a;
        word-break: break-all;
        text-align: right;
    }
    .vpn-badge-ok,
    .vpn-badge-bad {
        display: inline-block;
        min-width: 54px;
        padding: 2px 10px;
        border-radius: 999px;
        text-align: center;
        font-size: 12px;
        font-weight: 700;
    }
    .vpn-badge-ok {
        color: #166534;
        background: #dcfce7;
    }
    .vpn-badge-bad {
        color: #991b1b;
        background: #fee2e2;
    }
    .vpn-targets {
        display: flex;
        flex-direction: column;
        gap: 10px;
    }
    .vpn-target {
        padding: 12px 13px;
        border: 1px solid #eef1f4;
        border-radius: 12px;
        background: linear-gradient(180deg, #fbfcfd 0%, #f8fafc 100%);
    }
    .vpn-target-top {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 12px;
        margin-bottom: 8px;
    }
    .vpn-target-links a {
        margin-right: 12px;
    }
    .vpn-detail {
        margin-top: 12px;
        border: 1px solid #e7eaee;
        border-radius: 14px;
        background: #fff;
        overflow: hidden;
        box-shadow: 0 6px 16px rgba(15, 23, 42, 0.03);
    }
    .vpn-detail summary {
        padding: 12px 16px;
        cursor: pointer;
        font-weight: 700;
        background: #fafbfc;
    }
    .vpn-detail pre {
        margin: 0;
        padding: 14px 16px;
        white-space: pre-wrap;
        word-break: break-word;
        border-top: 1px solid #eef1f4;
        background: #fff;
        color: #0f172a;
    }
    .vpn-mini-note {
        margin-top: 8px;
        color: #66707c;
        font-size: 12px;
        line-height: 1.6;
    }
    .cbi-map .cbi-section,
    .cbi-map .cbi-section-node {
        border: 0;
        background: transparent;
        box-shadow: none;
    }
    .cbi-map .cbi-section-table,
    .cbi-map .table.cbi-section-table {
        width: 100%;
        border-collapse: separate;
        border-spacing: 0 10px;
        margin-top: 8px;
    }
    .cbi-map .cbi-section-table-row,
    .cbi-map .tr.cbi-section-table-row {
        background: #fff;
        border: 1px solid #e7eaee;
        border-radius: 14px;
        box-shadow: 0 6px 16px rgba(15, 23, 42, 0.03);
    }
    .cbi-map .cbi-section-table-row .td,
    .cbi-map .tr.cbi-section-table-row .td {
        padding: 12px 14px;
        vertical-align: middle;
    }
    .cbi-map input[type="text"],
    .cbi-map input[type="password"],
    .cbi-map input[type="file"],
    .cbi-map select,
    .cbi-map textarea {
        border: 1px solid #d7dde5;
        border-radius: 10px;
        background: #fff;
        transition: border-color .2s ease, box-shadow .2s ease;
    }
    .cbi-map input[type="text"]:focus,
    .cbi-map input[type="password"]:focus,
    .cbi-map input[type="file"]:focus,
    .cbi-map select:focus,
    .cbi-map textarea:focus {
        border-color: #2563eb;
        box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.12);
        outline: none;
    }
    .cbi-map .btn.cbi-button,
    .cbi-map .cbi-button,
    .cbi-map .cbi-button-add,
    .cbi-map .cbi-button-apply,
    .cbi-map .cbi-button-reset {
        border-radius: 10px;
        padding: 8px 14px;
    }
    .cbi-map .cbi-section-table .cbi-button-add {
        background: linear-gradient(135deg, #2563eb 0%, #0ea5e9 100%);
        border: 0;
        color: #fff;
        box-shadow: 0 8px 18px rgba(37, 99, 235, 0.18);
    }
    .cbi-map .cbi-section-table .cbi-button-add:hover {
        filter: brightness(1.03);
    }
    .cbi-map .vpn-output {
        padding: 12px 14px;
        border-radius: 12px;
        background: #fff7ed;
        border: 1px solid #fed7aa;
    }
    .vpn-toolbar {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        align-items: center;
    }
    .vpn-pill {
        display: inline-flex;
        align-items: center;
        padding: 4px 10px;
        border-radius: 999px;
        background: #eff6ff;
        color: #1d4ed8;
        font-size: 12px;
        font-weight: 700;
    }
    h4 {
        white-space: nowrap;
        border-bottom: 0;
        margin: 10px 5px 5px 5px;
    }
    .tr {
        border: 0;
        text-align: left;
    }
    .vpn-output {
        box-shadow: none;
        margin: 10px 5px 5px 5px;
        color: #a22;
    }
    textarea {
        border: 1px solid #cccccc;
        padding: 5px;
        font-size: 12px;
        font-family: monospace;
        resize: none;
        white-space: pre;
        overflow-wrap: normal;
        overflow-x: scroll;
    }
    a {
        line-height: 1.5;
    }
    hr {
        margin: 0.5em 0;
    }
</style>
EOF

    cat > /usr/lib/lua/luci/view/openvpn/pageswitch.htm <<'EOF'
<%#
 Copyright 2008 Steven Barth <steven@midlink.org>
 Copyright 2008 Jo-Philipp Wich <jow@openwrt.org>
 Licensed to the public under the Apache License 2.0.
-%>

<%+openvpn/ovpn_css%>

<%
local mode = self.mode or "basic"
local category_title = nil
if mode == "advanced" then
    for _, c in ipairs(self.categories or {}) do
        if c.id == self.category then
            category_title = c.title
            break
        end
    end
end
%>

<div class="vpn-shell">
  <div class="vpn-hero">
    <div class="vpn-toolbar">
      <span class="vpn-pill">OpenVPN</span>
      <% if mode == "basic" then %>
        <span class="vpn-status-chip">基础配置</span>
      <% else %>
        <span class="vpn-status-chip">高级配置</span>
      <% end %>
    </div>
    <h2>
      <a href="<%=url('admin/services/openvpn')%>"><%:Overview%></a> &#187;
      <%=luci.i18n.translatef("Instance \"%s\"", pcdata(self.instance))%>
    </h2>
    <p class="vpn-sub">
      <% if mode == "basic" then %>
        适合快速修改常用参数，保存后会自动应用到当前实例。
      <% else %>
        适合查看与编辑更细粒度的 OpenVPN 参数分组。
      <% end %>
    </p>
    <div class="vpn-hero-actions">
      <% if mode == "basic" then %>
        <a class="cbi-button" href="<%=url('admin/services/openvpn/advanced', self.instance)%>"><%:Switch to advanced configuration%></a>
      <% else %>
        <a class="cbi-button" href="<%=url('admin/services/openvpn/basic', self.instance)%>"><%:Switch to basic configuration%></a>
      <% end %>
      <a class="cbi-button" href="<%=url('nradioadv/system/openvpnfull')%>">OEM 视图</a>
    </div>
  </div>

  <% if mode == "advanced" then %>
    <div class="vpn-card" style="margin-bottom:14px;">
      <div class="vpn-card-title"><%:Configuration category%></div>
      <div class="vpn-toolbar">
        <% for i, c in ipairs(self.categories or {}) do %>
          <% if c.id == self.category then %>
            <span class="vpn-status-chip"><%=c.title%></span>
          <% else %>
            <a class="vpn-pill" href="<%=luci.dispatcher.build_url('admin','services','openvpn','advanced', self.instance, c.id)%>"><%=c.title%></a>
          <% end %>
        <% end %>
      </div>
      <% if category_title then %>
        <div class="vpn-mini-note">当前分类：<strong><%=category_title%></strong></div>
      <% end %>
    </div>
  <% end %>
</div>
EOF

    cat > /usr/lib/lua/luci/view/nradio_adv/openvpn_full.htm <<'EOF'
<%+header%>
<%
local util = require "luci.util"
local function cmd(c) return util.trim(util.exec(c) or "") end
local function esc(s) return luci.util.pcdata(s or "") end

local svc = cmd("/etc/init.d/openvpn status 2>/dev/null || true")
local ps_std = cmd("ps | grep 'openvpn(custom_config)' | grep -v grep")
local ps_legacy = cmd("ps | grep 'openvpn --config' | grep -v grep")
local ps = ps_std ~= "" and ps_std or ps_legacy
local tun = cmd("ip addr show tun0 2>/dev/null || echo tun0-down")
local rt = cmd("ip route | grep -E '11\.1|192\.168\.[239]\.0' 2>/dev/null")
local log = cmd("tail -40 /tmp/openvpn-client.log 2>/dev/null || logread 2>/dev/null | grep -i openvpn | tail -40")
local cfg = cmd("sed -n '1,160p' /etc/openvpn/client.ovpn 2>/dev/null")
local auth = cmd("sed -n '1,40p' /etc/openvpn/auth.txt 2>/dev/null")
local log_focus = cmd("(tail -120 /tmp/openvpn-client.log 2>/dev/null; logread 2>/dev/null) | grep -i -E 'openvpn|tun0|tls|auth|route|error|fail|warn' | tail -30")
local cfg_json = require("luci.util").serialize_json(cfg)
local tun_ip = tun:match("inet%s+([%d%.]+/%d+)") or "-"
local remote = cmd("awk '$1==\"remote\"{print $2\" \"$3; exit}' /etc/openvpn/client.ovpn 2>/dev/null")
local proto = cmd("awk '$1==\"proto\"{print $2; exit}' /etc/openvpn/client.ovpn 2>/dev/null")
local has_ca = cfg:find("<ca>") ~= nil
local has_cert = cfg:find("<cert>") ~= nil
local has_tls = cfg:find("<tls%-auth>") ~= nil or cfg:find("<tls%-crypt>") ~= nil
local has_auth = auth ~= ""
local connected = (((svc:match("running")) or ps ~= "") and tun:match("inet ")) and true or false
local mode = ps_std ~= "" and "UCI custom_config" or (ps_legacy ~= "" and "Legacy ovpn" or "Stopped")
local has_route2 = rt:match("192%.168%.2%.0/24") ~= nil
local has_route3 = rt:match("192%.168%.3%.0/24") ~= nil
local has_route9 = rt:match("192%.168%.9%.0/24") ~= nil
local route_count = (has_route2 and 1 or 0) + (has_route3 and 1 or 0) + (has_route9 and 1 or 0)

local function highlight_log(s)
    s = luci.util.pcdata(s or "")
    s = s:gsub("(TLS Error)", '<span style="color:#b91c1c;font-weight:700;">%1</span>')
    s = s:gsub("(AUTH FAILED)", '<span style="color:#b91c1c;font-weight:700;">%1</span>')
    s = s:gsub("(route)", '<span style="color:#1d4ed8;font-weight:700;">%1</span>')
    s = s:gsub("(tun0)", '<span style="color:#047857;font-weight:700;">%1</span>')
    s = s:gsub("(error)", '<span style="color:#b91c1c;font-weight:700;">%1</span>')
    s = s:gsub("(fail)", '<span style="color:#b91c1c;font-weight:700;">%1</span>')
    s = s:gsub("(warn)", '<span style="color:#d97706;font-weight:700;">%1</span>')
    return s
end

local function state_text(ok)
    return ok and "OK" or "FAIL"
end

local function state_class(ok)
    return ok and "vpn-badge-ok" or "vpn-badge-bad"
end
%>

<%+openvpn/ovpn_css%>

<div class="vpn-shell">
  <div class="vpn-hero">
    <div class="vpn-toolbar">
      <span class="vpn-pill">OpenVPN</span>
      <span class="vpn-status-chip <%=connected and '' or 'off'%>"><%=connected and '运行中' or '已停止'%></span>
    </div>
    <h2>OpenVPN 完整版</h2>
    <p class="vpn-sub">OEM 应用商店兼容页，展示当前隧道、认证、路由与日志，并支持一键重连。</p>
    <div class="vpn-hero-actions">
      <form method="post" action="<%=luci.dispatcher.build_url('nradioadv','system','openvpnfull','restart')%>">
        <input class="cbi-button cbi-button-apply" type="submit" value="重连 OpenVPN" />
      </form>
      <a class="cbi-button" href="<%=luci.dispatcher.build_url('nradioadv','system','openvpnfull')%>">刷新</a>
      <a class="cbi-button" href="#" onclick="(function(){var t=<%=cfg_json%>; if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).catch(function(){window.prompt('复制配置',t);});} else {window.prompt('复制配置',t);} })(); return false;">复制配置</a>
      <a class="cbi-button" href="<%=url('admin/services/openvpn')%>">标准 OpenVPN</a>
      <a class="cbi-button" href="<%=url('admin/services/openvpn/basic', 'custom_config')%>">基础配置</a>
      <a class="cbi-button" href="<%=url('admin/services/openvpn/advanced', 'custom_config')%>">高级配置</a>
    </div>
  </div>

  <div class="vpn-grid">
    <div class="vpn-card">
      <div class="vpn-card-title">运行状态</div>
      <div class="vpn-kv"><span>连接</span><strong class="<%=state_class(connected)%>"><%= connected and 'Connected' or 'Disconnected' %></strong></div>
      <div class="vpn-kv"><span>模式</span><strong><%=esc(mode)%></strong></div>
      <div class="vpn-kv"><span>进程</span><strong><%=esc(ps ~= '' and ps or 'no process')%></strong></div>
      <div class="vpn-kv"><span>隧道 IP</span><strong><%=esc(tun_ip)%></strong></div>
      <div class="vpn-kv"><span>远端</span><strong><%=esc(remote ~= '' and remote or '-')%></strong></div>
      <div class="vpn-kv"><span>协议</span><strong><%=esc(proto ~= '' and proto or '-')%></strong></div>
    </div>

    <div class="vpn-card">
      <div class="vpn-card-title">配置摘要</div>
      <div class="vpn-kv"><span>认证文件</span><strong><%=state_text(has_auth)%></strong></div>
      <div class="vpn-kv"><span>CA 证书</span><strong><%=state_text(has_ca)%></strong></div>
      <div class="vpn-kv"><span>客户端证书</span><strong><%=state_text(has_cert)%></strong></div>
      <div class="vpn-kv"><span>TLS 密钥</span><strong><%=state_text(has_tls)%></strong></div>
      <div class="vpn-kv"><span>配置路径</span><strong>/etc/openvpn/client.ovpn</strong></div>
      <div class="vpn-mini-note">建议把关键字段统一放在这个卡片里，便于快速定位配置是否完整。</div>
    </div>

    <div class="vpn-card">
      <div class="vpn-card-title">快速诊断</div>
      <div class="vpn-kv"><span>tun0</span><strong><%=state_text(tun:find('inet ') ~= nil)%></strong></div>
      <div class="vpn-kv"><span>日志命中</span><strong><%=state_text(log_focus ~= '')%></strong></div>
      <div class="vpn-kv"><span>默认路由</span><strong><%=state_text(rt ~= '')%></strong></div>
      <div class="vpn-kv"><span>配置完整</span><strong><%=state_text(has_ca and (has_auth or has_cert) and true or false)%></strong></div>
      <div class="vpn-mini-note">这块用来一眼判断是否“已经连上、配置齐、路由到位”。</div>
    </div>

    <div class="vpn-card">
      <div class="vpn-card-title">路由概览</div>
      <div class="vpn-kv"><span>远端网段</span><strong><%=state_text(route_count > 0)%></strong></div>
      <div class="vpn-kv"><span>已接入</span><strong><%=route_count%> 个</strong></div>
      <div class="vpn-kv"><span>显示</span><strong>已隐藏具体网段</strong></div>
      <div class="vpn-mini-note">具体网段已折叠到“路由信息”，首页仅保留汇总状态。</div>
    </div>
  </div>

  <details class="vpn-detail" open>
    <summary>进程信息</summary>
    <pre><%=esc(ps)%></pre>
  </details>

  <details class="vpn-detail" open>
    <summary>关键日志</summary>
    <pre><%=highlight_log(log_focus ~= '' and log_focus or 'no focus log')%></pre>
  </details>

  <details class="vpn-detail">
    <summary>隧道信息</summary>
    <pre><%=esc(tun)%></pre>
  </details>

  <details class="vpn-detail">
    <summary>路由信息</summary>
    <pre><%=esc(rt ~= '' and rt or 'no route')%></pre>
  </details>

  <details class="vpn-detail">
    <summary>客户端配置</summary>
    <pre><%=esc(cfg ~= '' and cfg or 'no config')%></pre>
  </details>

  <details class="vpn-detail">
    <summary>运行日志</summary>
    <pre><%=esc(log ~= '' and log or 'no log')%></pre>
  </details>
</div>
<%+footer%>
EOF
}


fix_openvpn_luci_compat() {
    for f in \
        /usr/lib/lua/luci/controller/openvpn.lua \
        /usr/lib/lua/luci/model/cbi/openvpn.lua \
        /usr/lib/lua/luci/model/cbi/openvpn-basic.lua \
        /usr/lib/lua/luci/model/cbi/openvpn-advanced.lua \
        /usr/lib/lua/luci/view/openvpn/pageswitch.htm \
        /usr/lib/lua/luci/view/openvpn/cbi-select-input-add.htm; do
        [ -f "$f" ] || continue
        backup_file "$f"
        sed -i \
            -e 's/"vpn", "openvpn"/"services", "openvpn"/g' \
            -e 's#admin/vpn/openvpn#admin/services/openvpn#g' \
            "$f"
    done

    if [ -f /usr/lib/lua/luci/view/openvpn/cbi-select-input-add.htm ]; then
        sed -i 's/luci.xml.pcdata(v)/pcdata(v)/g' /usr/lib/lua/luci/view/openvpn/cbi-select-input-add.htm
    fi
}

install_openvpn_core() {
    ensure_default_feeds
    mkdir -p "$WORKDIR/openvpn/core"

    openvpn_core_ipk="$WORKDIR/openvpn/core/openvpn-openssl.ipk"
    liblzo2_ipk="$WORKDIR/openvpn/core/liblzo2.ipk"
    liblzo2_fixed_ipk="$WORKDIR/openvpn/core/liblzo2-fixed.ipk"
    openvpn_core_fixed_ipk="$WORKDIR/openvpn/core/openvpn-openssl-fixed.ipk"
    kmod_tun_ipk="$WORKDIR/openvpn/core/kmod-tun.ipk"
    kmod_tun_fixed_ipk="$WORKDIR/openvpn/core/kmod-tun-fixed.ipk"
    target_arch="$(get_primary_arch)"

    [ -n "$target_arch" ] || die "OpenVPN core precheck failed: unable to determine current opkg architecture"

    if [ ! -e /usr/lib/libssl.so.1.1 ] || [ ! -e /usr/lib/libcrypto.so.1.1 ]; then
        die "OpenVPN core precheck failed: system libopenssl1.1 missing; repair system SSL library first"
    fi

    if [ ! -e /dev/net/tun ] || [ ! -e /sys/module/tun ] || ! opkg status kmod-tun >/dev/null 2>&1; then
        log "tip: downloading OpenVPN dependency kmod-tun via configured feed mirrors..."
        kmod_tun_url="$(resolve_package_url_any_feed kmod-tun 2>/dev/null || true)"
        [ -n "$kmod_tun_url" ] || { sed -n '1,80p' "$FEEDS" >&2; die "failed to resolve kmod-tun from current feeds"; }
        download_file "$kmod_tun_url" "$kmod_tun_ipk" || die "failed to download kmod-tun ipk"
        repack_ipk_control "$kmod_tun_ipk" "$kmod_tun_fixed_ipk" "$target_arch" "kernel"
        install_ipk_file "$kmod_tun_fixed_ipk" "OpenVPN kmod-tun"
    fi

    if [ ! -e /usr/lib/liblzo2.so.2 ] || ! opkg status liblzo2 >/dev/null 2>&1; then
        log "tip: downloading OpenVPN dependency liblzo2 via configured feed mirrors..."
        liblzo2_url="$(resolve_package_url_any_feed liblzo2 2>/dev/null || true)"
        [ -n "$liblzo2_url" ] || { sed -n '1,80p' "$FEEDS" >&2; die "failed to resolve liblzo2 from current feeds"; }
        download_file "$liblzo2_url" "$liblzo2_ipk" || die "failed to download liblzo2 ipk"
        repack_ipk_control "$liblzo2_ipk" "$liblzo2_fixed_ipk" "$target_arch" "libc"
        install_ipk_file "$liblzo2_fixed_ipk" "OpenVPN liblzo2"
    fi

    log "tip: downloading OpenVPN core via configured feed mirrors..."
    openvpn_core_url="$(resolve_package_url_any_feed openvpn-openssl 2>/dev/null || true)"
    [ -n "$openvpn_core_url" ] || { sed -n '1,80p' "$FEEDS" >&2; die "failed to resolve openvpn-openssl from current feeds"; }
    download_file "$openvpn_core_url" "$openvpn_core_ipk" || die "failed to download openvpn-openssl ipk"
    repack_ipk_control "$openvpn_core_ipk" "$openvpn_core_fixed_ipk" "$target_arch" "libc"
    if ! opkg install "$openvpn_core_fixed_ipk" >/tmp/openvpn-core-install.log 2>&1; then
        if [ -c /dev/net/tun ] || [ -e /sys/module/tun ]; then
            opkg install "$openvpn_core_fixed_ipk" --force-depends >/tmp/openvpn-core-install.log 2>&1 || {
                sed -n '1,200p' /tmp/openvpn-core-install.log >&2
                die "openvpn-openssl install failed"
            }
        else
            sed -n '1,200p' /tmp/openvpn-core-install.log >&2
            die "openvpn-openssl install failed, likely missing tun support"
        fi
    fi

    opkg status openvpn-openssl >/dev/null 2>&1 || die "OpenVPN core verify failed: package openvpn-openssl missing"
    if [ ! -e /dev/net/tun ] && [ ! -e /sys/module/tun ]; then
        opkg status kmod-tun >/dev/null 2>&1 || die "OpenVPN core verify failed: tun driver missing"
    fi
    command -v openvpn >/dev/null 2>&1 || [ -x /usr/sbin/openvpn ] || die "OpenVPN core verify failed: openvpn binary missing"
}

install_openvpn() {
    [ -f "$CFG" ] || die "appcenter config not found: $CFG"
    [ -f "$TPL" ] || die "appcenter template not found: $TPL"

    ensure_default_feeds

    mkdir -p "$WORKDIR/openvpn/pkg" "$WORKDIR/openvpn/data"
    ovpn_ipk="$WORKDIR/openvpn/luci-app-openvpn.ipk"
    log "tip: downloading OpenVPN LuCI package via configured feed mirrors..."
    ovpn_url="$(resolve_package_url_any_feed luci-app-openvpn 2>/dev/null || true)"
    [ -n "$ovpn_url" ] || { sed -n '1,80p' "$FEEDS" >&2; die "failed to resolve OpenVPN LuCI ipk from current feeds"; }
    download_file "$ovpn_url" "$ovpn_ipk" || die "failed to download OpenVPN LuCI ipk"
    [ -n "$OPENVPN_VERSION" ] || OPENVPN_VERSION="$(resolve_package_version_any_feed luci-app-openvpn 2>/dev/null || true)"
    ovpn_download_size="$(wc -c < "$ovpn_ipk" | tr -d ' ')"
    log "downloaded: OpenVPN LuCI $OPENVPN_VERSION ($ovpn_download_size bytes)"
    log "next step will install OpenVPN core + LuCI, then modify /etc/config/appcenter, $TPL and OpenVPN OEM files"
    confirm_or_exit "确认继续安装 OpenVPN 并修改系统吗？"

    install_openvpn_core

    extract_ipk_archive "$ovpn_ipk" "$WORKDIR/openvpn/pkg"
    [ -f "$WORKDIR/openvpn/pkg/data.tar.gz" ] || die "OpenVPN LuCI ipk missing data.tar.gz"
    [ -f "$WORKDIR/openvpn/pkg/control.tar.gz" ] || die "OpenVPN LuCI ipk missing control.tar.gz"
    tar -xzf "$WORKDIR/openvpn/pkg/data.tar.gz" -C "$WORKDIR/openvpn/data" >/dev/null 2>&1 || die "failed to extract OpenVPN LuCI payload"

    for needed in \
        usr/lib/lua/luci/controller/openvpn.lua \
        usr/lib/lua/luci/model/cbi/openvpn.lua \
        usr/lib/lua/luci/model/cbi/openvpn-basic.lua \
        usr/lib/lua/luci/model/cbi/openvpn-advanced.lua \
        usr/lib/lua/luci/view/openvpn/cbi-select-input-add.htm; do
        [ -f "$WORKDIR/openvpn/data/$needed" ] || die "OpenVPN LuCI package incomplete: missing $needed"
    done

    backup_file /usr/lib/lua/luci/controller/openvpn.lua
    backup_file /usr/lib/lua/luci/model/cbi/openvpn.lua
    backup_file /usr/lib/lua/luci/model/cbi/openvpn-basic.lua
    backup_file /usr/lib/lua/luci/model/cbi/openvpn-advanced.lua
    backup_file /usr/lib/lua/luci/model/cbi/openvpn-file.lua
    backup_file /usr/lib/lua/luci/view/openvpn/ovpn_css.htm
    backup_file /usr/lib/lua/luci/view/openvpn/pageswitch.htm
    backup_file /usr/lib/lua/luci/view/openvpn/cbi-select-input-add.htm
    backup_file /usr/lib/lua/luci/controller/nradio_adv/openvpn_full.lua
    backup_file /usr/lib/lua/luci/view/nradio_adv/openvpn_full.htm

    cp -rf "$WORKDIR/openvpn/data/etc" / >/dev/null 2>&1 || true
    cp -rf "$WORKDIR/openvpn/data/usr" / >/dev/null 2>&1 || true

    write_openvpn_wrapper_files
    fix_openvpn_luci_compat

    ovpn_size="$(wc -c < "$ovpn_ipk" | tr -d ' ')"
    backup_file "$CFG"
    set_appcenter_entry "OpenVPN" "luci-app-openvpn" "$OPENVPN_VERSION" "$ovpn_size" "/usr/lib/lua/luci/controller/nradio_adv/openvpn_full.lua" "nradioadv/system/openvpnfull"
    uci commit appcenter

    patch_common_template
    refresh_luci_appcenter
    verify_appcenter_route "OpenVPN" "nradioadv/system/openvpnfull"
    verify_file_exists /usr/lib/lua/luci/controller/nradio_adv/openvpn_full.lua "OpenVPN"
    verify_file_exists /usr/lib/lua/luci/view/nradio_adv/openvpn_full.htm "OpenVPN"
    verify_luci_route nradioadv/system/openvpnfull "OpenVPN"

    log "done"
    log "plugin:   OpenVPN"
    log "version:  $OPENVPN_VERSION"
    log "route:    nradioadv/system/openvpnfull"
    log "note:     OpenVPN 核心与 LuCI 页面已安装，OEM 应用商店兼容页已接入"
    log "next:     close appcenter popup, then press Ctrl+F5 and reopen OpenVPN"
}

configure_openvpn_runtime() {
    ovpn_dst="/etc/openvpn/client.ovpn"
    auth_dst="/etc/openvpn/auth.txt"
    hotplug_src="/etc/hotplug.d/iface/99-openvpn-route"
    hotplug_dst="/etc/hotplug.d/openvpn/99-openvpn-route"
    ca_tmp="$WORKDIR/openvpn-wizard-ca.crt"
    cert_tmp="$WORKDIR/openvpn-wizard-client.crt"
    key_tmp="$WORKDIR/openvpn-wizard-client.key"
    ta_tmp="$WORKDIR/openvpn-wizard-ta.key"
    extra_tmp="$WORKDIR/openvpn-wizard-extra.conf"

    command -v openvpn >/dev/null 2>&1 || [ -x /usr/sbin/openvpn ] || die "OpenVPN core not installed; run option 3 first"

    mkdir -p "$WORKDIR" /etc/openvpn /etc/hotplug.d/openvpn

    if [ -f "$ovpn_dst" ] && confirm_default_yes '检测到现有 OpenVPN 配置，是否直接复用当前配置并重启？'; then
        ensure_openvpn_profile_safety_flags "$ovpn_dst"
        /etc/init.d/openvpn enable >/dev/null 2>&1 || true
        /etc/init.d/openvpn restart >/tmp/openvpn-runtime-fix.log 2>&1 || true
        sleep 10
        if [ -f "$hotplug_dst" ]; then
            ACTION=up sh "$hotplug_dst" >/tmp/openvpn-route-apply.log 2>&1 || true
        fi
        tun_line="$(ip addr show tun0 2>/dev/null | grep -m1 'inet ' || true)"
        if [ -z "$tun_line" ]; then
            print_openvpn_runtime_debug
            die "OpenVPN runtime failed: current profile restart did not establish tun0"
        fi
        log "done"
        log "plugin:   OpenVPN runtime"
        log "profile:  $ovpn_dst"
        log "status:   $(/etc/init.d/openvpn status 2>/dev/null || true)"
        log "tun0:     $tun_line"
        log "note:     reused current profile"
        return 0
    fi

    load_openvpn_runtime_defaults_from_profile

    ovpn_verify_cn='0'
    ovpn_server_cn=''
    ovpn_key_direction='1'
    ovpn_user=''

    prompt_with_default '服务器域名' "${OVPN_SERVER:-}"
    ovpn_server="$PROMPT_RESULT"
    [ -n "$ovpn_server" ] || die "server domain is required"
    case "$ovpn_server" in
        *[[:space:]]*) die "server domain must not contain spaces" ;;
    esac

    prompt_with_default '端口号' "${OVPN_PORT:-1194}"
    ovpn_port="$PROMPT_RESULT"
    case "$ovpn_port" in
        *[!0-9]*|'') die "port must be numeric" ;;
    esac
    [ "$ovpn_port" -ge 1 ] && [ "$ovpn_port" -le 65535 ] || die "port must be between 1 and 65535"

    prompt_with_default '协议类型 tcp 还是 udp' "${OVPN_TRANSPORT:-udp}"
    ovpn_transport="$PROMPT_RESULT"
    [ "$ovpn_transport" = 'upd' ] && ovpn_transport='udp'
    case "$ovpn_transport" in
        tcp|TCP) ovpn_transport='tcp' ;;
        udp|UDP) ovpn_transport='udp' ;;
        *) die "protocol must be tcp or udp" ;;
    esac

    prompt_with_default 'IP 版本 ipv4 还是 ipv6' "${OVPN_FAMILY:-ipv6}"
    ovpn_family="$PROMPT_RESULT"
    case "$ovpn_family" in
        ipv4|4)
            ovpn_family='ipv4'
            if [ "$ovpn_transport" = 'tcp' ]; then
                ovpn_proto='tcp4-client'
            else
                ovpn_proto='udp4'
            fi
            ;;
        ipv6|6)
            ovpn_family='ipv6'
            if [ "$ovpn_transport" = 'tcp' ]; then
                ovpn_proto='tcp6-client'
            else
                ovpn_proto='udp6'
            fi
            ;;
        *)
            die "IP family must be ipv4 or ipv6"
            ;;
    esac

    resolved_ip="$(resolve_host_record "$ovpn_server" "$ovpn_family" 2>/dev/null || true)"
    [ -n "$resolved_ip" ] || die "server resolve failed: $ovpn_server has no usable $ovpn_family record"

    prompt_with_default '是否开启 lzo 压缩？(y/n)' "${OVPN_LZO:-n}"
    ovpn_lzo="$PROMPT_RESULT"
    case "$ovpn_lzo" in
        y|Y|yes|YES) ovpn_lzo='1' ;;
        n|N|no|NO) ovpn_lzo='0' ;;
        *) die "lzo choice must be y or n" ;;
    esac

    prompt_with_default '加密协议是什么？' "${OVPN_CIPHER:-AES-256-GCM}"
    ovpn_cipher="$PROMPT_RESULT"

    prompt_with_default 'MTU 值' "${OVPN_MTU:-1400}"
    ovpn_mtu="$PROMPT_RESULT"
    case "$ovpn_mtu" in
        *[!0-9]*|'') die "MTU must be numeric" ;;
    esac
    [ "$ovpn_mtu" -ge 576 ] && [ "$ovpn_mtu" -le 9000 ] || die "MTU must be between 576 and 9000"

    prompt_with_default '认证摘要算法（auth）是什么？' "${OVPN_AUTH_DIGEST:-}"
    ovpn_auth_digest="$PROMPT_RESULT"

    printf '提示: 如果你还不确定服务端要求什么，建议先选 1（仅用户名密码）验证是否能连通。\n'
    prompt_with_default '认证方式 [1=仅用户名密码, 2=仅客户端证书/私钥, 3=用户名密码+客户端证书/私钥]' "${OVPN_AUTH_MODE:-1}"
    ovpn_auth_mode="$PROMPT_RESULT"
    case "$ovpn_auth_mode" in
        1)
            ovpn_auth='1'
            ovpn_cert_auth='0'
            ;;
        2)
            ovpn_auth='0'
            ovpn_cert_auth='1'
            ;;
        3)
            ovpn_auth='1'
            ovpn_cert_auth='1'
            ;;
        *)
            die "auth mode must be 1, 2 or 3"
            ;;
    esac

    if [ "$ovpn_auth" = '1' ]; then
        if [ -f "$auth_dst" ]; then
            ovpn_user="$(sed -n '1p' "$auth_dst" 2>/dev/null || true)"
            ovpn_pass="$(sed -n '2p' "$auth_dst" 2>/dev/null || true)"
        else
            prompt_with_default '用户名' "${OVPN_USER:-}"
            ovpn_user="$PROMPT_RESULT"
            printf '密码: '
            read -r ovpn_pass || die "input cancelled"
        fi
        [ -n "$ovpn_user" ] || die "username is required"
        [ -n "$ovpn_pass" ] || die "password is required"
    fi

    if [ "$ovpn_cert_auth" = '1' ]; then
        printf '注意: 只有你手里明确有客户端证书/客户端私钥（通常类似 client.crt / client.key）时，才应该选择包含客户端证书的认证方式。\n'
    fi

    prompt_with_default '服务端证书校验模式 [1=兼容模式(CA校验), 2=严格模式(remote-cert-tls server)]' "${OVPN_SERVER_VERIFY:-1}"
    ovpn_server_verify="$PROMPT_RESULT"
    case "$ovpn_server_verify" in
        1)
            ovpn_server_verify='compat'
            ;;
        2)
            ovpn_server_verify='strict'
            ;;
        *)
            die "server verify mode must be 1 or 2"
            ;;
    esac

    ovpn_verify_cn='0'
    ovpn_server_cn=''
    if [ "$ovpn_server_verify" = 'compat' ]; then
        prompt_with_default '是否额外校验服务端证书 CN？(y/n)' "${OVPN_VERIFY_CN:-n}"
        ovpn_verify_cn="$PROMPT_RESULT"
        case "$ovpn_verify_cn" in
            y|Y|yes|YES)
                ovpn_verify_cn='1'
                prompt_with_default '服务端证书 CN（例如 iKuai OpenVPN Server）' "${OVPN_SERVER_CN:-}"
                ovpn_server_cn="$PROMPT_RESULT"
                [ -n "$ovpn_server_cn" ] || die "server certificate CN is required"
                ;;
            n|N|no|NO)
                ovpn_verify_cn='0'
                ;;
            *)
                die "CN verify choice must be y or n"
                ;;
        esac
    fi

    prompt_with_default '是否使用 tls-auth 或 tls-crypt 密钥？(n/auth/crypt)' "${OVPN_TLS_MODE:-n}"
    ovpn_tls_mode="$PROMPT_RESULT"
    case "$ovpn_tls_mode" in
        n|N|no|NO) ovpn_tls_mode='0' ;;
        auth|AUTH) ovpn_tls_mode='auth' ;;
        crypt|CRYPT) ovpn_tls_mode='crypt' ;;
        *) die "tls key mode must be n, auth or crypt" ;;
    esac

    printf '说明: CA 证书用于验证服务端；如果服务端要求双向证书认证，后面再填写客户端证书和客户端私钥。\n'
    : > "$ca_tmp"
    if [ -f "$RUNTIME_CA_FILE" ]; then
        cp "$RUNTIME_CA_FILE" "$ca_tmp"
    elif [ -f /etc/openvpn/client.ovpn ]; then
        extract_inline_block_to_file /etc/openvpn/client.ovpn ca "$ca_tmp"
    else
        printf '请粘贴 CA 证书内容（CA 用于验证服务端身份），结束请输入单独一行 EOF:\n'
        while IFS= read -r line; do
            [ "$line" = 'EOF' ] && break
            printf '%s\n' "$line" >> "$ca_tmp"
        done
    fi
    grep -q 'BEGIN CERTIFICATE' "$ca_tmp" || die "CA certificate format invalid"

    if [ "$ovpn_cert_auth" = '1' ]; then
        : > "$cert_tmp"
        if [ -f "$RUNTIME_CERT_FILE" ]; then
            cp "$RUNTIME_CERT_FILE" "$cert_tmp"
        elif [ -f /etc/openvpn/client.ovpn ]; then
            extract_inline_block_to_file /etc/openvpn/client.ovpn cert "$cert_tmp"
        else
            printf '请粘贴客户端证书内容（客户端身份认证证书，不是服务端证书），结束请输入单独一行 EOF:\n'
            while IFS= read -r line; do
                [ "$line" = 'EOF' ] && break
                printf '%s\n' "$line" >> "$cert_tmp"
            done
        fi
        grep -q 'BEGIN CERTIFICATE' "$cert_tmp" || die "client certificate format invalid"
        validate_client_certificate_if_possible "$cert_tmp"

        : > "$key_tmp"
        if [ -f "$RUNTIME_KEY_FILE" ]; then
            cp "$RUNTIME_KEY_FILE" "$key_tmp"
        elif [ -f /etc/openvpn/client.ovpn ]; then
            extract_inline_block_to_file /etc/openvpn/client.ovpn key "$key_tmp"
        else
            printf '请粘贴客户端私钥内容（与客户端证书对应的私钥），结束请输入单独一行 EOF:\n'
            while IFS= read -r line; do
                [ "$line" = 'EOF' ] && break
                printf '%s\n' "$line" >> "$key_tmp"
            done
        fi
        grep -Eq 'BEGIN (RSA )?PRIVATE KEY|BEGIN EC PRIVATE KEY' "$key_tmp" || die "client key format invalid"
        validate_client_cert_key_match_if_possible "$cert_tmp" "$key_tmp"
    fi

    if [ "$ovpn_tls_mode" != '0' ]; then
        if [ "$ovpn_tls_mode" = 'auth' ]; then
            prompt_with_default 'tls-auth 的 key-direction' "${OVPN_KEY_DIRECTION:-1}"
            ovpn_key_direction="$PROMPT_RESULT"
            case "$ovpn_key_direction" in
                0|1) ;;
                *) die "key-direction must be 0 or 1" ;;
            esac
        fi
        : > "$ta_tmp"
        if [ -f "$RUNTIME_TLS_FILE" ]; then
            cp "$RUNTIME_TLS_FILE" "$ta_tmp"
        elif [ -f /etc/openvpn/client.ovpn ]; then
            if [ "$ovpn_tls_mode" = 'auth' ]; then
                extract_inline_block_to_file /etc/openvpn/client.ovpn tls-auth "$ta_tmp"
            else
                extract_inline_block_to_file /etc/openvpn/client.ovpn tls-crypt "$ta_tmp"
            fi
        else
            printf '请粘贴 tls-auth/tls-crypt 密钥内容，结束请输入单独一行 EOF:\n'
            while IFS= read -r line; do
                [ "$line" = 'EOF' ] && break
                printf '%s\n' "$line" >> "$ta_tmp"
            done
        fi
        grep -q 'BEGIN OpenVPN Static key V1' "$ta_tmp" || die "tls-auth/tls-crypt key format invalid"
    fi

    prompt_with_default '是否需要追加额外 OpenVPN 指令？(y/n)' "${OVPN_EXTRA:-n}"
    ovpn_extra="$PROMPT_RESULT"
    case "$ovpn_extra" in
        y|Y|yes|YES)
            : > "$extra_tmp"
            if [ -f "$RUNTIME_EXTRA_FILE" ]; then
                cp "$RUNTIME_EXTRA_FILE" "$extra_tmp"
            else
                printf '请逐行粘贴额外指令，结束请输入单独一行 EOF:\n'
                while IFS= read -r line; do
                    [ "$line" = 'EOF' ] && break
                    printf '%s\n' "$line" >> "$extra_tmp"
                done
            fi
            ;;
        n|N|no|NO)
            ovpn_extra='0'
            ;;
        *)
            die "extra options choice must be y or n"
            ;;
    esac

    log "summary: OpenVPN profile will be written to $ovpn_dst"
    log "summary: server=$ovpn_server port=$ovpn_port proto=$ovpn_proto cipher=$ovpn_cipher mtu=$ovpn_mtu"
    [ "$ovpn_server_verify" = 'strict' ] && log "summary: server cert verify=remote-cert-tls server"
    [ "$ovpn_verify_cn" = '1' ] && log "summary: verify-x509-name=$ovpn_server_cn"
    [ -n "$ovpn_auth_digest" ] && log "summary: auth=$ovpn_auth_digest"
    [ "$ovpn_auth" = '1' ] && log "summary: auth file will be written to $auth_dst"
    [ "$ovpn_cert_auth" = '1' ] && log "summary: inline client cert/key will be written"
    [ "$ovpn_tls_mode" = 'auth' ] && log "summary: inline tls-auth key will be written (key-direction=$ovpn_key_direction)"
    [ "$ovpn_tls_mode" = 'crypt' ] && log "summary: inline tls-crypt key will be written"
    [ "$ovpn_extra" != '0' ] && log "summary: extra OpenVPN directives will be appended"
    confirm_or_exit "确认写入 OpenVPN 配置并启动吗？"

    backup_file "$ovpn_dst"
    [ -f "$auth_dst" ] && backup_file "$auth_dst"
    backup_file /etc/config/openvpn
    backup_file /etc/init.d/openvpn_client
    [ -f "$hotplug_dst" ] && backup_file "$hotplug_dst"

    {
        printf '%s\n' 'client'
        printf '%s\n' 'dev tun'
        printf 'proto %s\n' "$ovpn_proto"
        printf 'remote %s %s\n' "$ovpn_server" "$ovpn_port"
        printf '%s\n' 'resolv-retry infinite'
        printf '%s\n' 'nobind'
        printf '%s\n' 'persist-key'
        printf '%s\n' 'persist-tun'
        printf '%s\n' 'route-noexec'
        printf 'tun-mtu %s\n' "$ovpn_mtu"
        printf '%s\n' 'status /var/run/openvpn.custom_config.status 10'
        printf '%s\n' 'log /tmp/openvpn-client.log'
        printf '%s\n' 'verb 3'
    } > "$ovpn_dst"

    if [ "$ovpn_server_verify" = 'strict' ]; then
        cat >> "$ovpn_dst" <<'EOF'
remote-cert-tls server
EOF
    fi

    if [ "$ovpn_verify_cn" = '1' ]; then
        printf 'verify-x509-name "%s" name\n' "$ovpn_server_cn" >> "$ovpn_dst"
    fi

    if [ "$ovpn_auth" = '1' ]; then
        printf '%s\n%s\n' "$ovpn_user" "$ovpn_pass" > "$auth_dst"
        chmod 600 "$auth_dst"
        printf 'auth-user-pass %s\n' "$auth_dst" >> "$ovpn_dst"
        printf '%s\n' 'auth-nocache' >> "$ovpn_dst"
    else
        rm -f "$auth_dst"
    fi

    if [ -n "$ovpn_cipher" ]; then
        printf 'cipher %s\n' "$ovpn_cipher" >> "$ovpn_dst"
        printf 'data-ciphers %s\n' "$ovpn_cipher" >> "$ovpn_dst"
        printf 'data-ciphers-fallback %s\n' "$ovpn_cipher" >> "$ovpn_dst"
    fi

    if [ -n "$ovpn_auth_digest" ]; then
        printf 'auth %s\n' "$ovpn_auth_digest" >> "$ovpn_dst"
    fi

    if [ "$ovpn_lzo" = '1' ]; then
        cat >> "$ovpn_dst" <<'EOF'
comp-lzo yes
EOF
    fi

    cat >> "$ovpn_dst" <<EOF
<ca>
$(cat "$ca_tmp")
</ca>
EOF

    if [ "$ovpn_cert_auth" = '1' ]; then
        cat >> "$ovpn_dst" <<EOF
<cert>
$(cat "$cert_tmp")
</cert>
<key>
$(cat "$key_tmp")
</key>
EOF
    fi

    if [ "$ovpn_tls_mode" = 'auth' ]; then
        cat >> "$ovpn_dst" <<EOF
key-direction $ovpn_key_direction
<tls-auth>
$(cat "$ta_tmp")
</tls-auth>
EOF
    fi

    if [ "$ovpn_tls_mode" = 'crypt' ]; then
        cat >> "$ovpn_dst" <<EOF
<tls-crypt>
$(cat "$ta_tmp")
</tls-crypt>
EOF
    fi

    if [ "$ovpn_extra" != '0' ]; then
        printf '\n' >> "$ovpn_dst"
        cat "$extra_tmp" >> "$ovpn_dst"
        printf '\n' >> "$ovpn_dst"
    fi

    chmod 600 "$ovpn_dst"
    save_openvpn_runtime_state

    uci set openvpn.custom_config=openvpn
    uci set openvpn.custom_config.enabled='1'
    uci set openvpn.custom_config.config="$ovpn_dst"
    uci commit openvpn

    if [ -f /etc/init.d/openvpn_client ]; then
        /etc/init.d/openvpn_client disable >/dev/null 2>&1 || true
        /etc/init.d/openvpn_client stop >/dev/null 2>&1 || true
    fi

    if [ -f "$hotplug_src" ] && [ ! -f "$hotplug_dst" ]; then
        cp "$hotplug_src" "$hotplug_dst"
    fi
    if [ -f "$hotplug_dst" ]; then
        sed -i 's/ifup)/up|ifup)/' "$hotplug_dst"
        chmod 755 "$hotplug_dst"
    fi

    /etc/init.d/openvpn enable >/dev/null 2>&1 || true
    /etc/init.d/openvpn stop >/dev/null 2>&1 || true
    killall openvpn 2>/dev/null || true
    rm -f /tmp/openvpn-runtime-fix.log /tmp/openvpn-client.log /var/run/openvpn.custom_config.status /var/run/openvpn.custom_config.pid 2>/dev/null || true
    sleep 2

    /etc/init.d/openvpn restart >/tmp/openvpn-runtime-fix.log 2>&1 || true
    sleep 12

    if [ -f "$hotplug_dst" ]; then
        ACTION=up sh "$hotplug_dst" >/tmp/openvpn-route-apply.log 2>&1 || true
    fi

    ovpn_status="$(/etc/init.d/openvpn status 2>/dev/null || true)"
    tun_line="$(ip addr show tun0 2>/dev/null | grep -m1 'inet ' || true)"
    route_hits="$(ip route | grep 'dev tun0' || true)"
    runtime_log_text="$(sed -n '1,120p' /tmp/openvpn-client.log 2>/dev/null; sed -n '1,120p' /tmp/openvpn-runtime-fix.log 2>/dev/null)"
    verify_file_exists "$ovpn_dst" "OpenVPN runtime"

    if [ -z "$tun_line" ]; then
        print_openvpn_runtime_debug
        print_openvpn_runtime_hints "$ovpn_cert_auth" "$ovpn_tls_mode" "$ovpn_proto" "$runtime_log_text"
        die "OpenVPN runtime failed: tun0 not established"
    fi

    log "done"
    log "plugin:   OpenVPN runtime"
    log "profile:  $ovpn_dst"
    [ "$ovpn_auth" = '1' ] && log "auth:     $auth_dst"
    log "status:   ${ovpn_status:-unknown}"
    log "tun0:     ${tun_line:-missing}"
    if [ -n "$route_hits" ]; then
        log "routes:   detected via tun0"
    else
        log "routes:   not detected"
    fi
    log "note:     full log at /tmp/openvpn-runtime-fix.log"
}

configure_openvpn_routes() {
    hotplug_dst="/etc/hotplug.d/openvpn/99-openvpn-route"
    route_tmp="$WORKDIR/openvpn-route.rules"
    map_route_tmp="$WORKDIR/openvpn-map-peers.rules"

    mkdir -p /etc/hotplug.d/openvpn "$WORKDIR"
    clear_openvpn_route_state_vars
    if [ -f "$ROUTE_STATE_FILE" ] && confirm_default_yes '复用上次保存的路由基础设置吗？'; then
        load_openvpn_route_state
    fi

    case "${ROUTE_NAT:-}" in
        1) ROUTE_NAT='y' ;;
        0) ROUTE_NAT='n' ;;
    esac
    case "${ROUTE_FORWARD:-}" in
        1) ROUTE_FORWARD='y' ;;
        0) ROUTE_FORWARD='n' ;;
    esac
    case "${ROUTE_ENHANCED:-}" in
        1) ROUTE_ENHANCED='y' ;;
        0) ROUTE_ENHANCED='n' ;;
    esac
    case "${ROUTE_MAP_ENABLE:-}" in
        1) ROUTE_MAP_ENABLE='y' ;;
        0) ROUTE_MAP_ENABLE='n' ;;
    esac

    prompt_with_default '本地 LAN 接口' "${ROUTE_LAN_IF:-br-lan}"
    lan_if="$PROMPT_RESULT"
    case "$lan_if" in
        *[[:space:]]*) die 'LAN interface must not contain spaces' ;;
    esac

    prompt_with_default 'VPN 接口名' "${ROUTE_TUN_IF:-tun0}"
    tun_if="$PROMPT_RESULT"
    case "$tun_if" in
        *[[:space:]]*) die 'VPN interface must not contain spaces' ;;
    esac

    lan_default_subnet="$(get_default_lan_subnet 2>/dev/null || true)"
    [ -n "$lan_default_subnet" ] || lan_default_subnet='192.168.66.0/24'
    [ -n "${ROUTE_LAN_SUBNET:-}" ] && lan_default_subnet="$ROUTE_LAN_SUBNET"
    printf '本地 LAN 网段（例如 192.168.66.0/24） [%s]: ' "$lan_default_subnet"
    read -r lan_subnet
    [ -n "$lan_subnet" ] || lan_subnet="$lan_default_subnet"
    case "$lan_subnet" in
        */*) ;;
        *) die 'LAN subnet must be CIDR format' ;;
    esac
    lan_subnet_norm="$(normalize_ipv4_cidr "$lan_subnet" 2>/dev/null || true)"
    [ -n "$lan_subnet_norm" ] || die 'LAN subnet format invalid'
    lan_subnet="$lan_subnet_norm"

    tun_default_subnet="${ROUTE_TUN_SUBNET:-}"
    if [ -z "$tun_default_subnet" ]; then
        tun_default_subnet="$(get_interface_subnet "$tun_if" 2>/dev/null || true)"
        if [ -n "$tun_default_subnet" ]; then
            tun_default_subnet="$(normalize_ipv4_cidr "$tun_default_subnet" 2>/dev/null || true)"
        fi
    fi
    prompt_with_default 'VPN 隧道网段（客户端地址池所在网段，例如 11.1.0.0/16；留空则不单独添加）' "$tun_default_subnet"
    tun_subnet="$PROMPT_RESULT"
    if [ -n "$tun_subnet" ]; then
        case "$tun_subnet" in
            */*) ;;
            *) die 'VPN subnet must be CIDR format' ;;
        esac
        tun_subnet_norm="$(normalize_ipv4_cidr "$tun_subnet" 2>/dev/null || true)"
        [ -n "$tun_subnet_norm" ] || die 'VPN subnet format invalid'
        tun_subnet="$tun_subnet_norm"
    fi

    prompt_with_default '是否添加 NAT 伪装（MASQUERADE）？(y/n)' "${ROUTE_NAT:-y}"
    route_nat="$PROMPT_RESULT"
    case "$route_nat" in
        y|Y|yes|YES) route_nat='1' ;;
        n|N|no|NO) route_nat='0' ;;
        *) die 'NAT choice must be y or n' ;;
    esac

    prompt_with_default '是否添加 FORWARD 放行规则？(y/n)' "${ROUTE_FORWARD:-y}"
    route_forward="$PROMPT_RESULT"
    case "$route_forward" in
        y|Y|yes|YES) route_forward='1' ;;
        n|N|no|NO) route_forward='0' ;;
        *) die 'FORWARD choice must be y or n' ;;
    esac

    prompt_with_default '是否启用互访增强模式（统一 tun 网段并补策略路由）？(y/n)' "${ROUTE_ENHANCED:-y}"
    route_enhanced="$PROMPT_RESULT"
    case "$route_enhanced" in
        y|Y|yes|YES) route_enhanced='1' ;;
        n|N|no|NO) route_enhanced='0' ;;
        *) die 'enhanced mode choice must be y or n' ;;
    esac

    prompt_with_default '是否自动补齐 NAT 映射互访（映射目标、主机/网段路由、proxy_arp、客户端回程SNAT）？(y/n)' "${ROUTE_MAP_ENABLE:-n}"
    route_map_enable="$PROMPT_RESULT"
    case "$route_map_enable" in
        y|Y|yes|YES) route_map_enable='1' ;;
        n|N|no|NO) route_map_enable='0' ;;
        *) die 'mapping complement choice must be y or n' ;;
    esac

    map_ip=''
    map_host=''
    map_kind=''
    map_subnet=''
    lan_host_ip=''
    : > "$map_route_tmp"
    if [ "$route_map_enable" = '1' ]; then
        prompt_with_default '本机映射地址或映射网段（单 IP 例如 192.168.66.167；整段例如 192.168.167.0/24）' "${ROUTE_MAP_IP:-}"
        map_ip="$PROMPT_RESULT"
        [ -n "$map_ip" ] || die 'mapped LAN IP is required when mapping complement is enabled'
        map_parse_result="$(parse_map_target "$map_ip" 2>/dev/null || true)"
        [ -n "$map_parse_result" ] || die 'mapped LAN IP format invalid'
        map_kind="${map_parse_result%%|*}"
        map_ip_value="${map_parse_result#*|}"
        if [ "$map_kind" = 'host' ]; then
            map_host="$map_ip_value"
            map_ip="$map_host/32"
            map_subnet=''
        else
            map_host=''
            map_ip="$map_ip_value"
            map_subnet="$map_ip"
            [ "${map_subnet##*/}" = "${lan_subnet##*/}" ] || die 'subnet mapping requires the mapped subnet prefix length to match the local LAN subnet prefix length'
            [ "$map_subnet" = "$lan_subnet" ] && die 'mapped subnet must not equal local LAN subnet'
        fi

        lan_host_ip="$(get_interface_subnet "$lan_if" 2>/dev/null | cut -d/ -f1)"
        [ -n "$lan_host_ip" ] || lan_host_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
        lan_host_ip="$(normalize_ipv4_host "$lan_host_ip" 2>/dev/null || true)"
        [ -n "$lan_host_ip" ] || die 'failed to detect local LAN host IP'
        [ "$map_kind" = 'host' ] && [ "$map_host" = "$lan_host_ip" ] && die 'mapped host must not equal local LAN host IP'

        if [ -s "$ROUTE_MAP_LIST_FILE" ] && confirm_default_yes '复用已保存的映射对端列表吗？'; then
            cp "$ROUTE_MAP_LIST_FILE" "$map_route_tmp"
        else
            while :; do
                printf '对端映射地址或网段（留空结束，例如 192.168.66.166 或 192.168.167.0/24）: '
                read -r peer_map_ip
                [ -z "$peer_map_ip" ] && break
                peer_parse_result="$(parse_map_target "$peer_map_ip" 2>/dev/null || true)"
                [ -n "$peer_parse_result" ] || die 'peer mapped target format invalid'
                peer_map_kind="${peer_parse_result%%|*}"
                peer_map_target="${peer_parse_result#*|}"
                if [ "$peer_map_kind" = 'host' ]; then
                    [ "$peer_map_target" = "$map_host" ] && die 'peer mapped target must not equal local mapped target'
                else
                    [ "$peer_map_target" = "$lan_subnet" ] && die 'peer mapped subnet must not equal local LAN subnet'
                    [ -n "$map_subnet" ] && [ "$peer_map_target" = "$map_subnet" ] && die 'peer mapped target must not equal local mapped target'
                fi
                grep -q "^$peer_map_target|" "$map_route_tmp" 2>/dev/null && die "duplicate mapped peer target: $peer_map_target"
                printf '该映射地址对应的对端隧道 IP（例如 11.1.1.4）: '
                read -r peer_map_gw
                peer_map_gw_norm="$(normalize_ipv4_host "$peer_map_gw" 2>/dev/null || true)"
                [ -n "$peer_map_gw_norm" ] || die 'peer tunnel IP format invalid'
                printf '%s|%s|%s\n' "$peer_map_target" "$peer_map_gw_norm" "$peer_map_kind" >> "$map_route_tmp"
            done
        fi

        if [ -s "$map_route_tmp" ]; then
            map_route_tmp_norm="$WORKDIR/openvpn-map-peers.normalized"
            : > "$map_route_tmp_norm"
            while IFS='|' read -r peer_map_target peer_map_gw peer_map_kind_saved; do
                [ -n "$peer_map_target" ] || continue
                [ -n "$peer_map_kind_saved" ] || peer_map_kind_saved="$(infer_map_target_kind "$peer_map_target")"
                if [ "$peer_map_kind_saved" = 'host' ]; then
                    peer_map_target="${peer_map_target%/*}"
                fi
                printf '%s|%s|%s\n' "$peer_map_target" "$peer_map_gw" "$peer_map_kind_saved" >> "$map_route_tmp_norm"
            done < "$map_route_tmp"
            mv "$map_route_tmp_norm" "$map_route_tmp"
        fi

        [ -s "$map_route_tmp" ] || die 'at least one mapped peer target is required when mapping complement is enabled'
    fi

    tun_supernet=''
    tun_route_verify="$tun_subnet"
    if [ "$route_enhanced" = '1' ] && [ -n "$tun_subnet" ]; then
        tun_supernet="$(derive_supernet16_from_cidr "$tun_subnet" 2>/dev/null || true)"
        [ -n "$tun_supernet" ] || die 'failed to derive tunnel supernet from VPN subnet'
        tun_route_verify="$tun_supernet"
    fi

    : > "$route_tmp"
    if [ -f "$ROUTE_LIST_FILE" ] && confirm_default_yes '复用已保存的远端网段列表吗？'; then
        cp "$ROUTE_LIST_FILE" "$route_tmp"
    else
        while :; do
            printf '远端网段（你希望通过 OpenVPN 访问到的对端局域网，留空结束，例如 192.168.2.0/24）: '
            read -r remote_subnet
            [ -z "$remote_subnet" ] && break
            case "$remote_subnet" in
                */*) ;;
                *) die 'remote subnet must be CIDR format' ;;
            esac
            remote_subnet_norm="$(normalize_ipv4_cidr "$remote_subnet" 2>/dev/null || true)"
            [ -n "$remote_subnet_norm" ] || die 'remote subnet format invalid'
            remote_subnet="$remote_subnet_norm"
            printf '该网段对应的对端隧道 IP（例如 11.1.1.1）: '
            read -r remote_gw
            [ -n "$remote_gw" ] || die 'gateway is required'
            case "$remote_gw" in
                */*) die 'gateway must be a host IP, not CIDR' ;;
            esac
            grep -q "^$remote_subnet|" "$route_tmp" 2>/dev/null && die "duplicate remote subnet: $remote_subnet"
            printf '%s|%s\n' "$remote_subnet" "$remote_gw" >> "$route_tmp"
        done
    fi

    [ -s "$route_tmp" ] || die 'at least one remote subnet is required'

    log "summary: OpenVPN 路由脚本将写入 $hotplug_dst"
    log "summary: 本地 LAN 接口=$lan_if 本地 LAN 网段=$lan_subnet"
    log "summary: VPN 接口=$tun_if"
    [ -n "$tun_subnet" ] && log "summary: VPN 隧道网段=$tun_subnet"
    [ "$route_nat" = '1' ] && log "summary: NAT masquerade will be added"
    [ "$route_forward" = '1' ] && log "summary: FORWARD accept rules will be added"
    [ "$route_enhanced" = '1' ] && log "summary: enhanced mode enabled (tun supernet + policy rules)"
    if [ "$route_map_enable" = '1' ]; then
        if [ "$map_kind" = 'host' ]; then
            log "summary: mapping complement enabled local-host=$map_ip -> $lan_host_ip"
        else
            log "summary: mapping complement enabled local-subnet=$map_subnet -> $lan_subnet"
        fi
        if [ -s "$map_route_tmp" ]; then
            log "summary: mapped peer list"
            while IFS='|' read -r peer_map_target peer_map_gw peer_map_kind_saved; do
                [ -n "$peer_map_target" ] || continue
                [ -n "$peer_map_kind_saved" ] || peer_map_kind_saved="$(infer_map_target_kind "$peer_map_target")"
                log "  - $peer_map_target via $peer_map_gw ($peer_map_kind_saved)"
            done < "$map_route_tmp"
        fi
    fi
    log "summary: route list"
    while IFS='|' read -r subnet gw; do
        log "  - $subnet via $gw"
    done < "$route_tmp"
    [ -f "$ROUTE_LIST_FILE" ] && log "summary: saved route list file=$ROUTE_LIST_FILE"
    confirm_or_exit "确认写入 OpenVPN 路由脚本吗？"

    backup_file "$hotplug_dst"

    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' ''
        printf '%s\n' '[ "$ACTION" = "up" ] || [ "$ACTION" = "ifup" ] || exit 0'
        printf '%s\n' ''
        printf '%s\n' 'LAN_IF="'"$lan_if"'"'
        printf '%s\n' 'TUN_IF="'"$tun_if"'"'
        printf '%s\n' 'LAN_SUBNET="'"$lan_subnet"'"'
        if [ -n "$tun_subnet" ]; then
            printf '%s\n' 'TUN_SUBNET="'"$tun_subnet"'"'
        else
            printf '%s\n' 'TUN_SUBNET=""'
        fi
        if [ "$route_enhanced" = '1' ] && [ -n "$tun_supernet" ]; then
            printf '%s\n' 'TUN_SUPERNET="'"$tun_supernet"'"'
        else
            printf '%s\n' 'TUN_SUPERNET=""'
        fi
        if [ "$route_map_enable" = '1' ]; then
            printf '%s\n' 'MAP_KIND="'"$map_kind"'"'
            printf '%s\n' 'MAP_IP="'"$map_ip"'"'
            printf '%s\n' 'MAP_HOST="'"$map_host"'"'
            printf '%s\n' 'MAP_SUBNET="'"$map_subnet"'"'
            printf '%s\n' 'LAN_HOST_IP="'"$lan_host_ip"'"'
        else
            printf '%s\n' 'MAP_KIND=""'
            printf '%s\n' 'MAP_IP=""'
            printf '%s\n' 'MAP_HOST=""'
            printf '%s\n' 'MAP_SUBNET=""'
            printf '%s\n' 'LAN_HOST_IP=""'
        fi
        printf '%s\n' ''
        printf '%s\n' 'apply_routes() {'
        printf '%s\n' '    [ -d "/sys/class/net/$TUN_IF" ] || exit 0'
        printf '%s\n' '    cleanup_target_rules() {'
        printf '%s\n' '        target="$1"'
        printf '%s\n' '        pri=60'
        printf '%s\n' '        while [ "$pri" -le 119 ]; do'
        printf '%s\n' '            ip rule del to "$target" lookup main priority "$pri" 2>/dev/null || true'
        printf '%s\n' '            ip rule del iif "$LAN_IF" to "$target" lookup main priority "$pri" 2>/dev/null || true'
        printf '%s\n' '            pri=$((pri + 1))'
        printf '%s\n' '        done'
        printf '%s\n' '    }'
        if [ "$route_enhanced" = '1' ]; then
            printf '%s\n' '    CUR_IP=$(ip -4 addr show dev "$TUN_IF" | awk '\''/inet /{print $2; exit}'\'' | cut -d/ -f1)'
            printf '%s\n' '    [ -n "$CUR_IP" ] || exit 0'
            printf '%s\n' '    ip link set "$TUN_IF" up'
            printf '%s\n' '    [ -n "$TUN_SUBNET" ] && ip route del "$TUN_SUBNET" 2>/dev/null'
            printf '%s\n' '    [ -n "$TUN_SUPERNET" ] && ip route del "$TUN_SUPERNET" 2>/dev/null'
            printf '%s\n' '    [ -n "$TUN_SUPERNET" ] && ip route add "$TUN_SUPERNET" dev "$TUN_IF" 2>/dev/null'
        else
            printf '%s\n' '    [ -n "$TUN_SUBNET" ] && ip route replace "$TUN_SUBNET" dev "$TUN_IF" 2>/dev/null'
        fi
        printf '%s\n' '    TO_ROUTE_PRI=60'
        printf '%s\n' '    IIF_ROUTE_PRI=70'
        if [ "$route_map_enable" = '1' ]; then
            printf '%s\n' '    if [ "$MAP_KIND" = "host" ]; then'
            printf '%s\n' '        ip -4 addr show dev "$LAN_IF" | grep -q "inet ${MAP_IP}" || ip addr add "$MAP_IP" dev "$LAN_IF" 2>/dev/null'
            printf '%s\n' '        [ -w "/proc/sys/net/ipv4/conf/all/proxy_arp" ] && echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp'
            printf '%s\n' '        [ -w "/proc/sys/net/ipv4/conf/$LAN_IF/proxy_arp" ] && echo 1 > /proc/sys/net/ipv4/conf/$LAN_IF/proxy_arp'
            printf '%s\n' '        iptables -t nat -C PREROUTING -i "$TUN_IF" -d "$MAP_HOST" -j DNAT --to-destination "$LAN_HOST_IP" >/dev/null 2>&1 || iptables -t nat -I PREROUTING 1 -i "$TUN_IF" -d "$MAP_HOST" -j DNAT --to-destination "$LAN_HOST_IP"'
            printf '%s\n' '        iptables -t nat -C OUTPUT -d "$MAP_HOST" -j DNAT --to-destination "$LAN_HOST_IP" >/dev/null 2>&1 || iptables -t nat -I OUTPUT 1 -d "$MAP_HOST" -j DNAT --to-destination "$LAN_HOST_IP"'
            printf '%s\n' '    else'
            printf '%s\n' '        iptables -t nat -C PREROUTING -i "$TUN_IF" -d "$MAP_SUBNET" -j NETMAP --to "$LAN_SUBNET" >/dev/null 2>&1 || iptables -t nat -I PREROUTING 1 -i "$TUN_IF" -d "$MAP_SUBNET" -j NETMAP --to "$LAN_SUBNET"'
            printf '%s\n' '        iptables -t nat -C OUTPUT -d "$MAP_SUBNET" -j NETMAP --to "$LAN_SUBNET" >/dev/null 2>&1 || iptables -t nat -I OUTPUT 1 -d "$MAP_SUBNET" -j NETMAP --to "$LAN_SUBNET"'
            printf '%s\n' '    fi'
            while IFS='|' read -r peer_map_target peer_map_gw peer_map_kind_saved; do
                [ -n "$peer_map_target" ] || continue
                if [ "$peer_map_kind_saved" = 'host' ]; then
                    peer_map_match="$peer_map_target/32"
                    printf '%s\n' "    ip neigh replace proxy \"$peer_map_target\" dev \"\$LAN_IF\" 2>/dev/null || ip neigh add proxy \"$peer_map_target\" dev \"\$LAN_IF\" 2>/dev/null || true"
                else
                    peer_map_match="$peer_map_target"
                fi
                printf '%s\n' "    cleanup_target_rules \"$peer_map_match\""
                printf '%s\n' "    ip route replace \"$peer_map_match\" via \"$peer_map_gw\" dev \"\$TUN_IF\" 2>/dev/null"
                printf '%s\n' "    iptables -t nat -C POSTROUTING -s \"\$LAN_SUBNET\" -d \"$peer_map_match\" -o \"\$TUN_IF\" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s \"\$LAN_SUBNET\" -d \"$peer_map_match\" -o \"\$TUN_IF\" -j MASQUERADE"
                printf '%s\n' "    iptables -C FORWARD -s \"\$LAN_SUBNET\" -d \"$peer_map_match\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -s \"\$LAN_SUBNET\" -d \"$peer_map_match\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT"
                printf '%s\n' "    iptables -C FORWARD -s \"$peer_map_match\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -s \"$peer_map_match\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT"
                printf '%s\n' "    ip rule del to \"$peer_map_match\" lookup main priority \$TO_ROUTE_PRI 2>/dev/null"
                printf '%s\n' "    ip rule add to \"$peer_map_match\" lookup main priority \$TO_ROUTE_PRI"
                printf '%s\n' '    TO_ROUTE_PRI=$((TO_ROUTE_PRI + 1))'
                printf '%s\n' "    ip rule del iif \"\$LAN_IF\" to \"$peer_map_match\" lookup main priority \$IIF_ROUTE_PRI 2>/dev/null"
                printf '%s\n' "    ip rule add iif \"\$LAN_IF\" to \"$peer_map_match\" lookup main priority \$IIF_ROUTE_PRI"
                printf '%s\n' '    IIF_ROUTE_PRI=$((IIF_ROUTE_PRI + 1))'
            done < "$map_route_tmp"
        fi
        while IFS='|' read -r subnet gw; do
            [ -n "$subnet" ] || continue
            printf '%s\n' "    cleanup_target_rules \"$subnet\""
            printf '%s\n' "    ip route replace \"$subnet\" via \"$gw\" dev \"\$TUN_IF\" 2>/dev/null"
            if [ "$route_nat" = '1' ]; then
                printf '%s\n' "    iptables -t nat -C POSTROUTING -s \"\$LAN_SUBNET\" -d \"$subnet\" -o \"\$TUN_IF\" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s \"\$LAN_SUBNET\" -d \"$subnet\" -o \"\$TUN_IF\" -j MASQUERADE"
            fi
            if [ "$route_forward" = '1' ]; then
                printf '%s\n' "    iptables -C FORWARD -s \"$subnet\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -s \"$subnet\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT"
                printf '%s\n' "    iptables -C FORWARD -d \"$subnet\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -d \"$subnet\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT"
            fi
            printf '%s\n' "    ip rule del to \"$subnet\" lookup main priority \$TO_ROUTE_PRI 2>/dev/null"
            printf '%s\n' "    ip rule add to \"$subnet\" lookup main priority \$TO_ROUTE_PRI"
            printf '%s\n' '    TO_ROUTE_PRI=$((TO_ROUTE_PRI + 1))'
            printf '%s\n' "    ip rule del iif \"\$LAN_IF\" to \"$subnet\" lookup main priority \$IIF_ROUTE_PRI 2>/dev/null"
            printf '%s\n' "    ip rule add iif \"\$LAN_IF\" to \"$subnet\" lookup main priority \$IIF_ROUTE_PRI"
            printf '%s\n' '    IIF_ROUTE_PRI=$((IIF_ROUTE_PRI + 1))'
        done < "$route_tmp"
        if [ "$route_enhanced" = '1' ]; then
            pri=196
            while IFS='|' read -r subnet gw; do
                [ -n "$subnet" ] || continue
                printf '%s\n' "    ip rule del from \"\$LAN_SUBNET\" to \"$subnet\" lookup main priority $pri 2>/dev/null"
                printf '%s\n' "    ip rule add from \"\$LAN_SUBNET\" to \"$subnet\" lookup main priority $pri"
                pri=$((pri + 1))
            done < "$route_tmp"
        fi
        printf '%s\n' '}'
        printf '%s\n' ''
        printf '%s\n' 'apply_routes'
    } > "$hotplug_dst"

    chmod 755 "$hotplug_dst"
    sh -n "$hotplug_dst" >/dev/null 2>&1 || die 'generated OpenVPN route script has syntax error'

    save_openvpn_route_state

    route_apply_status='skipped'
    if [ -d "/sys/class/net/$tun_if" ]; then
        ACTION=up sh "$hotplug_dst" >/tmp/openvpn-route-apply.log 2>&1 || {
            sed -n '1,120p' /tmp/openvpn-route-apply.log >&2
            die 'failed to apply OpenVPN route script immediately'
        }
        while IFS='|' read -r subnet gw; do
            ip route | grep -q "^$subnet via $gw dev $tun_if" || die "route apply failed: missing $subnet via $gw dev $tun_if"
        done < "$route_tmp"
        if [ "$route_map_enable" = '1' ]; then
            if [ "$map_kind" = 'host' ]; then
                ip -4 addr show dev "$lan_if" | grep -q "inet $map_ip" || die "route apply failed: missing mapped LAN IP $map_ip on $lan_if"
            fi
            while IFS='|' read -r peer_map_target peer_map_gw peer_map_kind_saved; do
                [ -n "$peer_map_target" ] || continue
                [ -n "$peer_map_kind_saved" ] || peer_map_kind_saved="$(infer_map_target_kind "$peer_map_target")"
                if [ "$peer_map_kind_saved" = 'host' ]; then
                    peer_map_verify="${peer_map_target%/*}"
                else
                    peer_map_verify="$peer_map_target"
                fi
                ip route | grep -q "^$peer_map_verify via $peer_map_gw dev $tun_if" || die "route apply failed: missing mapped peer route $peer_map_verify via $peer_map_gw dev $tun_if"
            done < "$map_route_tmp"
        fi
        if [ -n "$tun_route_verify" ]; then
            ip route | grep -q "^$tun_route_verify dev $tun_if" || die "route apply failed: missing tunnel subnet $tun_route_verify dev $tun_if"
        fi
        route_apply_status='applied'
    fi

    log "done"
    log "plugin:   OpenVPN routes"
    log "script:   $hotplug_dst"
    log "lan-if:   $lan_if"
    log "lan-net:  $lan_subnet"
    [ -n "$tun_subnet" ] && log "tun-net:  $tun_subnet"
    log "apply:    $route_apply_status"
    log "note:     routes will also be applied on OpenVPN up/ifup"
}

install_ttyd_webssh() {
    helper="$WORKDIR/nradio-ttyd-webssh-embedded.sh"
    mkdir -p "$WORKDIR"
    cat > "$helper" <<'__TTYD_HELPER__'
#!/bin/sh
set -eu
umask 077

APP_NAME="ttyd Web SSH 助手"
TTYD_VERSION="1.7.7"
TTYD_RELEASE_MIRRORS="${TTYD_RELEASE_MIRRORS:-https://ghproxy.net/https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION}"
TTYD_RAW_MIRRORS="${TTYD_RAW_MIRRORS:-https://ghproxy.net/https://raw.githubusercontent.com/ozon/luci-app-ttyd/master https://cdn.jsdelivr.net/gh/ozon/luci-app-ttyd@master https://raw.githubusercontent.com/ozon/luci-app-ttyd/master}"
BACKUP_DIR="/root/ttyd-webssh-backup"
WORKDIR="/tmp/ttyd-webssh.$$"

cleanup() {
    rm -rf "$WORKDIR"
}

trap cleanup EXIT INT TERM

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_root() {
    [ "$(id -u)" = "0" ] || die "run as root"
}

ensure_workdir() {
    mkdir -p "$WORKDIR" "$BACKUP_DIR"
}

backup_file() {
    path="$1"
    [ -f "$path" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp "$path" "$BACKUP_DIR/$(basename "$path").$$.bak"
}

download_file() {
    download_url="$1"
    download_out="$2"
    download_tmp="$download_out.tmp"

    rm -f "$download_tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 --max-time 900 -o "$download_tmp" "$download_url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -O "$download_tmp" "$download_url" || return 1
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$download_tmp" "$download_url" || return 1
    else
        die "need curl, wget or uclient-fetch"
    fi

    [ -s "$download_tmp" ] || return 1
    mv "$download_tmp" "$download_out"
}

download_from_mirrors() {
    rel="$1"
    out="$2"
    mirrors="$3"

    for base in $mirrors; do
        if download_file "$base/$rel" "$out"; then
            return 0
        fi
    done

    return 1
}

fetch_luci_file() {
    rel="$1"
    out="$2"
    pattern="$3"
    fetch_tmp="$WORKDIR/$(basename "$out").fetch"

    rm -f "$fetch_tmp"
    for base in $TTYD_RAW_MIRRORS; do
        if download_file "$base/$rel" "$fetch_tmp" && grep -q "$pattern" "$fetch_tmp"; then
            [ -f "$out" ] && backup_file "$out"
            mv "$fetch_tmp" "$out"
            return 0
        fi
    done

    rm -f "$fetch_tmp"
    return 1
}

map_ttyd_arch() {
    case "$1" in
        x86_64) printf '%s\n' x86_64 ;;
        i?86) printf '%s\n' i686 ;;
        aarch64*|arm64*) printf '%s\n' aarch64 ;;
        armv7*|armv6*|armv8*|arm*) printf '%s\n' armhf ;;
        mips64el) printf '%s\n' mips64el ;;
        mips64) printf '%s\n' mips64 ;;
        mipsel) printf '%s\n' mipsel ;;
        mips*) printf '%s\n' mips ;;
        s390x) printf '%s\n' s390x ;;
        ppc64le) printf '%s\n' ppc64le ;;
        ppc64|powerpc64) printf '%s\n' ppc64 ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

get_lan_iface() {
    iface="$(uci -q get network.lan.device 2>/dev/null || true)"
    [ -n "$iface" ] || iface="$(uci -q get network.lan.ifname 2>/dev/null || true)"
    [ -n "$iface" ] || iface="br-lan"
    printf '%s\n' "$iface"
}

get_lan_ip() {
    ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 || true
}

install_ttyd_binary() {
    arch="$(map_ttyd_arch "$(uname -m 2>/dev/null || echo unknown)")"
    bin_name="ttyd.$arch"
    bin_tmp="$WORKDIR/$bin_name"
    sum_tmp="$WORKDIR/SHA256SUMS"

    log "downloading ttyd binary from CDN..."
    download_from_mirrors "$bin_name" "$bin_tmp" "$TTYD_RELEASE_MIRRORS" || die "failed to download $bin_name"
    download_from_mirrors "SHA256SUMS" "$sum_tmp" "$TTYD_RELEASE_MIRRORS" || die "failed to download SHA256SUMS"

    expected="$(awk -v f="$bin_name" '$2==f {print $1; exit}' "$sum_tmp")"
    [ -n "$expected" ] || die "checksum entry missing for $bin_name"
    actual="$(sha256sum "$bin_tmp" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || die "checksum mismatch for $bin_name"

    backup_file /usr/bin/ttyd
    cp "$bin_tmp" /usr/bin/ttyd
    chmod 755 /usr/bin/ttyd
    /usr/bin/ttyd --help >/dev/null 2>&1 || die "ttyd binary check failed"
}

write_ttyd_init_script() {
    init_file="/etc/init.d/ttyd"
    [ -f "$init_file" ] && backup_file "$init_file"
    cat > "$init_file" <<'EOF'
#!/bin/sh /etc/rc.common

START=30
USE_PROCD=1

EXTRA_COMMANDS="status"
EXTRA_HELP="status	Print runtime information"

ttyd="/usr/bin/ttyd"
ttyd_params=""
ttyd_run="/bin/sh"

start_service()
{
    config_load ttyd
    config_get port default port 7681
    config_get_bool use_credential default credential 0
    config_get username default username
    config_get password default password
    config_get shell default shell /bin/sh
    config_get interface default interface
    config_get_bool once default once 0
    config_get_bool ssl default ssl 0
    config_get_bool readonly default readonly 0
    config_get_bool check_origin default check_origin 0
    config_get max_clients default max_clients 0
    config_get reconnect default reconnect 10
    config_get signal default signal HUP
    config_get index default index
    config_get uid default uid
    config_get gid default gid

    [ -n "$port" ] && ttyd_params="${ttyd_params} --port $port"
    [ -n "$interface" ] && ttyd_params="${ttyd_params} --interface $interface"
    [ "$once" = 1 ] && ttyd_params="${ttyd_params} --once"
    [ "$ssl" = 1 ] && ttyd_params="${ttyd_params} --ssl"
    [ "$readonly" = 1 ] && ttyd_params="${ttyd_params} --readonly"
    [ "$readonly" != 1 ] && ttyd_params="${ttyd_params} --writable"
    [ "$check_origin" = 1 ] && ttyd_params="${ttyd_params} --check-origin"
    [ "$max_clients" != 0 ] && ttyd_params="${ttyd_params} --max-clients $max_clients"
    [ "$reconnect" != 10 ] && ttyd_params="${ttyd_params} --reconnect $reconnect"
    [ -n "$signal" ] && ttyd_params="${ttyd_params} --signal $signal"
    [ -n "$index" ] && ttyd_params="${ttyd_params} --index $index"
    [ "$use_credential" = 1 ] && ttyd_params="${ttyd_params} --credential ${username}:${password}"
    [ -n "$uid" ] && ttyd_params="${ttyd_params} --uid $uid"
    [ -n "$gid" ] && ttyd_params="${ttyd_params} --gid $gid"
    [ -n "$shell" ] && ttyd_run="$shell"

    procd_open_instance "ttyd"
    procd_set_param command ${ttyd} ${ttyd_params} ${ttyd_run} --login
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile /var/run/ttyd.pid
    procd_close_instance
}

reload_service()
{
    rc_procd start_service reload
}

restart()
{
    rc_procd start_service restart
}

status()
{
    if [ "$(pgrep ttyd 2>/dev/null | head -n 1)" ]; then
        echo 1
    else
        echo 0
    fi
}
EOF
    chmod 755 "$init_file"
}

write_ttyd_config() {
    config_file="/etc/config/ttyd"
    [ -f "$config_file" ] && backup_file "$config_file"
    cat > "$config_file" <<'EOF'
config server 'default'
    option once '0'
    option port '7681'
    option shell '/bin/sh'
    option check_origin '1'
    option max_clients '0'
EOF
}

write_ttyd_cbi_model() {
    model_file="/usr/lib/lua/luci/model/cbi/ttyd.lua"
    [ -f "$model_file" ] && backup_file "$model_file"
    cat > "$model_file" <<'EOF'
local fs = require("nixio.fs")
local util = require("luci.util")
local ttydcfg = "/etc/config/ttyd"

if not fs.access(ttydcfg) then
    m = SimpleForm("error", nil, "未找到配置文件，请检查 ttyd 配置。")
    m.reset = false
    m.submit = false
    return m
end

m = Map("ttyd", "配置")
s = m:section(TypedSection, "server")
s.addremove = false
s.anonymous = true

once = s:option(Flag, "once", "单次模式", "仅允许一个客户端连接，断开后自动退出")
once.rmempty = true

shells = s:option(ListValue, "shell", "Shell", "选择要启动的 Shell")
local shell_file = fs.readfile("/etc/shells") or "/bin/sh\n/bin/ash\n"
for i in string.gmatch(shell_file, "%S+") do
    shells:value(i)
end
shells.rmempty = false

port = s:option(Value, "port", "端口", "监听端口（默认 7681，填 0 表示随机端口）")
port.default = 7681
port.datatype = "port"
port.rmempty = true
port.placeholder = 7681

iface = s:option(Value, "interface", "接口", "绑定的网络接口（如 eth0），也可填写 UNIX 套接字路径（如 /var/run/ttyd.sock）")
iface.template = "cbi/network_netlist"
iface.nocreate = true
iface.unspecified = true
iface.nobridges = true
iface.optional = true

signals = s:option(ListValue, "signal", "退出信号", "会话退出时发送给命令的信号（默认 SIGHUP）")
local signal_text = util.exec("ttyd --signal-list 2>/dev/null") or ""
for i in string.gmatch(signal_text, "[^\r\n]+") do
    signals:value(string.match(i, "%u+"), string.sub(i, 4))
end
signals.rmempty = true
signals.optional = true

ssl = s:option(Flag, "ssl", "启用 SSL", "启用 HTTPS/WSS")
ssl.rmempty = true

ssl_cert = s:option(FileUpload, "ssl_cert", "SSL 证书文件", "证书文件路径"):depends("ssl", 1)
ssl_key = s:option(FileUpload, "ssl_key", "SSL 私钥文件", "私钥文件路径"):depends("ssl", 1)
ssl_ca = s:option(FileUpload, "ssl_ca", "SSL CA 文件", "客户端证书校验所需的 CA 文件路径"):depends("ssl", 1)

reconnect = s:option(Value, "reconnect", "重连时间", "客户端断开后的自动重连秒数（默认 10）")
reconnect.datatype = "integer"
reconnect.rmempty = true
reconnect.placeholder = 10
reconnect.optional = true

readonly = s:option(Flag, "readonly", "只读模式", "禁止客户端向终端写入")
readonly.rmempty = true
readonly.optional = true

check_origin = s:option(Flag, "check_origin", "同源校验", "禁止来自不同来源的 WebSocket 连接")
check_origin.rmempty = true
check_origin.optional = true

max_clients = s:option(Value, "max_clients", "最大客户端数", "最大并发客户端数量（默认 0，不限制）")
max_clients.datatype = "integer"
max_clients.rmempty = true
max_clients.placeholder = 0
max_clients.optional = true

credential = s:option(Flag, "credential", "启用基础认证", "使用用户名和密码进行访问认证")
credential.rmempty = true

credential_username = s:option(Value, "username", "用户名", "基础认证用户名")
credential_username:depends("credential", 1)
credential_username.rmempty = true

credential_password = s:option(Value, "password", "密码", "基础认证密码")
credential_password:depends("credential", 1)
credential_password.rmempty = true

debug = s:option(Value, "debug", "调试级别", "设置日志级别（默认 7）")
debug.datatype = "integer"
debug.rmempty = true
debug.placeholder = "7"
debug.optional = true

uid = s:option(Value, "uid", "用户 ID", "运行 ttyd 使用的用户 ID")
uid.rmempty = true
uid.optional = true

gid = s:option(Value, "gid", "组 ID", "运行 ttyd 使用的组 ID")
gid.rmempty = true
gid.optional = true

client_option = s:option(Value, "client_option", "客户端参数", "发送给客户端的参数（格式：key=value，可重复添加）")
client_option.rmempty = true
client_option.optional = true

index = s:option(Value, "index", "自定义 index.html", "自定义首页文件路径")
index.rmempty = true
index.optional = true

return m
EOF
}

install_luci_ttyd() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi /usr/lib/lua/luci/view/ttyd /etc/init.d /etc/config
    log "downloading LuCI ttyd resources via CDN..."

    fetch_luci_file "luasrc/controller/ttyd.lua" "/usr/lib/lua/luci/controller/ttyd.lua" 'module("luci.controller.ttyd"' || die "failed to download ttyd controller"
    fetch_luci_file "luasrc/model/cbi/ttyd.lua" "/usr/lib/lua/luci/model/cbi/ttyd.lua" 'Map("ttyd"' || die "failed to download ttyd cbi model"
    fetch_luci_file "luasrc/view/ttyd/overview.htm" "/usr/lib/lua/luci/view/ttyd/overview.htm" 'ttyd' || die "failed to download ttyd overview view"

    write_ttyd_init_script
    write_ttyd_config
    write_ttyd_cbi_model

    uci -q set ttyd.default=server
    uci -q set ttyd.default.once='0'
    uci -q set ttyd.default.port='7681'
    uci -q set ttyd.default.shell='/bin/sh'
    uci -q set ttyd.default.check_origin='1'
    uci -q set ttyd.default.max_clients='0'
    uci -q delete ttyd.default.interface || true
    uci -q commit ttyd
}

install_webssh_wrapper() {
    controller="/usr/lib/lua/luci/controller/nradio_adv/webssh.lua"
    view="/usr/lib/lua/luci/view/nradio_adv/webssh.htm"

    mkdir -p "$(dirname "$controller")" "$(dirname "$view")"
    [ -f "$controller" ] && backup_file "$controller"
    cat > "$controller" <<'EOF'
module("luci.controller.nradio_adv.webssh", package.seeall)

function index()
    entry({"nradioadv", "system", "webssh"}, template("nradio_adv/webssh"), nil, 91)
    entry({"nradioadv", "system", "webssh", "restart"}, call("restart"), nil, 92).leaf = true
    entry({"nradioadv", "system", "webssh", "uninstall"}, call("uninstall"), nil, 93).leaf = true
    entry({"nradioadv", "system", "appcenter", "webssh"}, alias("nradioadv", "system", "webssh"), nil, nil, true).leaf = true
end

function restart()
    local http = require "luci.http"
    local dsp = require "luci.dispatcher"

    os.execute("/etc/init.d/ttyd restart >/dev/null 2>&1")
    http.redirect(dsp.build_url("nradioadv", "system", "webssh"))
end

function uninstall()
    local http = require "luci.http"
    local dsp = require "luci.dispatcher"

    os.execute("/etc/init.d/ttyd stop >/dev/null 2>&1")
    os.execute("/etc/init.d/ttyd disable >/dev/null 2>&1")
    os.execute("rm -f /usr/bin/ttyd /etc/init.d/ttyd /etc/config/ttyd /usr/lib/lua/luci/controller/ttyd.lua /usr/lib/lua/luci/model/cbi/ttyd.lua /usr/lib/lua/luci/view/ttyd/overview.htm /usr/lib/lua/luci/controller/nradio_adv/webssh.lua /usr/lib/lua/luci/view/nradio_adv/webssh.htm")
    os.execute("sed -i '/app_list.result.applist.unshift({name:\"Web SSH\"/d' /usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm >/dev/null 2>&1")
    os.execute("rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* >/dev/null 2>&1")
    os.execute("/etc/init.d/uhttpd reload >/dev/null 2>&1")
    http.redirect(dsp.build_url("nradioadv", "system", "appcenter"))
end
EOF

    [ -f "$view" ] && backup_file "$view"
    cat > "$view" <<'EOF'
<%+header%>
<%
local util = require "luci.util"
local http = require "luci.http"
local dsp = require "luci.dispatcher"
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local installed = fs.access("/usr/bin/ttyd") and fs.access("/etc/init.d/ttyd")
local status = installed and util.trim(util.exec("/etc/init.d/ttyd status 2>/dev/null || true")) or ""
local ttyd_ps = installed and util.trim(util.exec("pgrep -af ttyd 2>/dev/null || true")) or ""
local running = ttyd_ps ~= "" or status == "1" or status:lower():find("running", 1, true) ~= nil
local ttyd_proc_count = installed and util.trim(util.exec("pgrep -c ttyd 2>/dev/null || true")) or "0"
if ttyd_proc_count == "" then
    ttyd_proc_count = "0"
end
local lan_ip = uci:get("network", "lan", "ipaddr") or util.trim(util.exec("ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1")) or "192.168.1.1"
local host = http.getenv("HTTP_HOST") or http.getenv("SERVER_NAME") or lan_ip
host = host:gsub(":%d+$", "")
if host == "" or host == "0.0.0.0" or host == "::" or host == "localhost" then
    host = lan_ip
end
local bind_iface = uci:get("ttyd", "default", "interface") or ""
local bind_iface_label = bind_iface ~= "" and bind_iface or "全部接口"
local bind_port = uci:get("ttyd", "default", "port") or "7681"
local ttyd_url = "http://" .. host .. ":" .. bind_port .. "/"
local ssh_cmd = "ssh root@" .. lan_ip
local listen_line = installed and util.trim(util.exec("netstat -lnt 2>/dev/null | grep -m1 ':" .. bind_port .. " ' || true")) or ""
local iface_line = bind_iface ~= "" and installed and util.trim(util.exec("ip link show " .. bind_iface .. " 2>/dev/null || true")) or ""
local client_limit = uci:get("ttyd", "default", "max_clients") or "0"
local client_limit_label = client_limit == "0" and "无限制" or client_limit
local runtime_label = installed and (running and "运行中" or "已停止") or "未安装"
local proc_check_label = installed and ttyd_ps ~= "" and "正常" or "缺失"
local port_check_label = installed and listen_line ~= "" and "监听中" or "未监听"
local iface_check_label = bind_iface == "" and "全部接口" or (installed and iface_line ~= "" and "存在" or "缺失")
local self_check_label = installed and proc_check_label == "正常" and port_check_label == "监听中" and (bind_iface == "" or iface_check_label == "存在") and "通过" or "异常"
local restart_url = dsp.build_url("nradioadv", "system", "webssh", "restart")
%>
<style>
.webssh-shell{max-width:1120px;margin:20px auto;padding:0 16px 28px}
.webssh-hero{position:relative;overflow:hidden;padding:26px;border:1px solid #dbe5ee;border-radius:22px;background:linear-gradient(180deg,#f8fbff 0%,#ffffff 56%,#f8fafc 100%);box-shadow:0 18px 50px rgba(15,23,42,.08)}
.webssh-hero:before{content:"";position:absolute;right:-66px;top:-66px;width:200px;height:200px;border-radius:999px;background:radial-gradient(circle,rgba(37,99,235,.16) 0%,rgba(37,99,235,0) 72%)}
.webssh-hero:after{content:"";position:absolute;left:-58px;bottom:-58px;width:160px;height:160px;border-radius:999px;background:radial-gradient(circle,rgba(14,165,233,.12) 0%,rgba(14,165,233,0) 70%)}
.webssh-head{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start;justify-content:space-between;position:relative;z-index:1}
.webssh-brand{display:flex;gap:14px;align-items:flex-start;min-width:0}
.webssh-icon{width:50px;height:50px;border-radius:16px;background:linear-gradient(135deg,#2563eb 0%,#0ea5e9 100%);color:#fff;display:flex;align-items:center;justify-content:center;font-size:20px;box-shadow:0 12px 18px rgba(37,99,235,.24)}
.webssh-title{margin:0;font-size:28px;line-height:1.15;color:#0f172a}
.webssh-desc{margin-top:8px;color:#5b6472;line-height:1.7;max-width:66ch}
.webssh-statusline{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}
.webssh-chip{display:inline-flex;align-items:center;gap:8px;padding:5px 12px;border-radius:999px;background:#dcfce7;color:#166534;font-weight:700;font-size:12px;letter-spacing:.02em}
.webssh-chip.off{background:#fee2e2;color:#991b1b}
.webssh-chip.soft{background:#e0edff;color:#1d4ed8}
.webssh-chip.gray{background:#eef2f7;color:#475569}
.webssh-grid{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(300px,.8fr);gap:16px;margin-top:18px;position:relative;z-index:1;align-items:stretch}
.webssh-card{display:flex;flex-direction:column;min-height:100%;box-sizing:border-box;padding:18px;border:1px solid #e6edf5;border-radius:18px;background:rgba(255,255,255,.96)}
.webssh-card h3{margin:0 0 12px;font-size:15px;color:#0f172a}
.webssh-kvlist{display:grid;gap:10px;flex:1}
.webssh-kv{display:flex;justify-content:space-between;gap:14px;padding:10px 0;border-bottom:1px solid #eef2f7;font-size:14px}
.webssh-kv:last-child{border-bottom:0}
.webssh-kv span{color:#64748b}
.webssh-kv strong{color:#0f172a;word-break:break-all;text-align:right}
.webssh-url{display:block;padding:14px 16px;border-radius:14px;background:#0f172a;color:#dbeafe;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:13px;word-break:break-all;box-shadow:inset 0 0 0 1px rgba(148,163,184,.18)}
.webssh-command{display:flex;align-items:center;gap:10px;padding:12px 14px;border-radius:14px;background:#0f172a;color:#dbeafe;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:13px;word-break:break-all;box-shadow:inset 0 0 0 1px rgba(148,163,184,.18)}
.webssh-command code{background:transparent;padding:0;color:inherit}
.webssh-ops{display:flex;flex-wrap:wrap;gap:10px;margin-top:14px}
.webssh-fillgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:16px}
.webssh-fillcard{padding:14px;border-radius:14px;background:#f8fafc;border:1px solid #e5ebf2}
.webssh-fillcard h4{margin:0 0 10px;font-size:13px;color:#0f172a}
.webssh-fillcard p{margin:0 0 10px;color:#64748b;font-size:12px;line-height:1.7}
.webssh-fillcard ul{margin:0;padding-left:18px;color:#475569;font-size:12px;line-height:1.8}
.webssh-fillcard li+li{margin-top:4px}
.webssh-quicklist{display:grid;gap:8px}
.webssh-quickbtn{display:block;padding:10px 12px;border-radius:12px;background:#fff;border:1px solid #e6edf5;color:#334155;font-size:12px;line-height:1.5;text-decoration:none}
.webssh-quickbtn strong{display:block;color:#0f172a;font-size:12px;margin-bottom:2px}
.webssh-quickbtn code{display:block;background:transparent;padding:0;color:#475569;font-size:11px}
.webssh-actions{display:flex;flex-wrap:wrap;gap:10px;justify-content:flex-end;align-items:center}
.webssh-actions .cbi-button,.webssh-ops .cbi-button{padding:9px 14px;border-radius:12px}
.webssh-note{margin-top:12px;color:#64748b;line-height:1.7;font-size:13px}
.webssh-footer{margin-top:14px;padding-top:12px;border-top:1px dashed #e8edf3;color:#64748b;font-size:12px;line-height:1.7}
.webssh-runtime-alert{margin-top:14px;padding:12px 14px;border:1px solid #fed7aa;border-radius:14px;background:#fff7ed;color:#9a3412;font-size:13px;line-height:1.6}
.webssh-toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:space-between;margin-bottom:12px}
.webssh-toolbar-left,.webssh-toolbar-right{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.webssh-mini-btn{display:inline-flex;align-items:center;justify-content:center;padding:7px 12px;border:1px solid #d9e2ec;border-radius:10px;background:#fff;color:#334155;font-size:12px;text-decoration:none;cursor:pointer}
.webssh-mini-btn.active{background:#0f172a;border-color:#0f172a;color:#dbeafe}
.webssh-mini-btn:hover{border-color:#94a3b8;color:#0f172a}
.webssh-terminal{margin-top:16px}
.webssh-terminal-frame{display:block;width:100%;height:640px;border:0;border-radius:14px;background:#0f172a;overflow:hidden;transition:height .18s ease}
.webssh-focus-banner{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px;padding:12px 14px;border:1px dashed #cbd5e1;border-radius:14px;background:#f8fafc;color:#475569;font-size:12px;line-height:1.7}
.webssh-inline-meta{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px}
.webssh-alert{display:none;margin-bottom:12px;padding:12px 14px;border:1px solid #fecaca;border-radius:14px;background:#fff1f2;color:#9f1239;font-size:13px;line-height:1.6}
.webssh-tiprow{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin-top:16px;position:relative;z-index:1;align-items:stretch}
.webssh-tip{display:flex;align-items:center;min-height:100%;box-sizing:border-box;padding:12px 14px;border-radius:14px;background:#f8fafc;border:1px solid #e5ebf2;color:#334155;font-size:13px;line-height:1.6}
@media (max-width: 920px){.webssh-grid,.webssh-tiprow,.webssh-fillgrid{grid-template-columns:1fr}.webssh-actions{justify-content:flex-start}.webssh-inline-meta{align-items:flex-start}.webssh-toolbar{align-items:flex-start}}
</style>
<div class="webssh-shell">
  <div class="webssh-hero">
    <div class="webssh-head">
      <div class="webssh-brand">
        <div class="webssh-icon"><i class="fas fa-terminal"></i></div>
        <div>
          <div class="webssh-chip <%=running and '' or 'off'%>"><%=runtime_label%></div>
          <h2 class="webssh-title">Web SSH / ttyd</h2>
          <div class="webssh-desc">浏览器直接打开路由器命令行，适合应急维护、查看日志和快速排障。页面会给出可用地址、绑定接口和端口，不需要再翻配置文件。</div>
          <div class="webssh-statusline">
            <span class="webssh-chip soft">接口 <%=bind_iface_label%></span>
            <span class="webssh-chip gray">端口 <%=bind_port%></span>
            <span class="webssh-chip gray">上限 <%=client_limit_label%></span>
            <span id="webssh-updated" class="webssh-chip gray">状态已加载</span>
          </div>
        </div>
      </div>
      <div class="webssh-actions">
        <% if installed then %>
          <a class="cbi-button cbi-button-apply" href="<%=ttyd_url%>" target="_blank" rel="noopener noreferrer">打开终端</a>
          <a class="cbi-button" href="<%=restart_url%>">重启 ttyd</a>
          <a class="cbi-button cbi-button-reset" href="#" onclick="window.location.reload(); return false;">刷新状态</a>
          <a class="cbi-button cbi-button-reset" href="#" onclick="return copy_text('<%=ttyd_url%>');">复制地址</a>
          <a class="cbi-button cbi-button-reset" href="#" onclick="return copy_text('<%=ssh_cmd%>');">复制 SSH 命令</a>
        <% else %>
          <span class="webssh-note">ttyd 还没安装，请先运行总脚本的 3 号选项。</span>
        <% end %>
      </div>
    </div>
    <% if self_check_label ~= "通过" then %>
    <div class="webssh-runtime-alert">当前自检未完全通过。可以先点“重启 ttyd”再刷新页面；如果内嵌终端仍然空白，优先使用“打开终端”或“全屏打开”。</div>
    <% end %>
    <div class="webssh-grid">
      <div class="webssh-card">
        <h3>连接信息</h3>
        <a class="webssh-url" href="<%=ttyd_url%>" target="_blank" rel="noopener noreferrer"><%=ttyd_url%></a>
        <div class="webssh-note">建议直接在新标签页打开。如果你从 HTTPS 管理页进入，这个页面会保持轻量，不再嵌入黑屏框架。</div>
        <div class="webssh-ops">
          <a class="cbi-button cbi-button-reset" href="<%=dsp.build_url('admin', 'system', 'ttyd', 'overview')%>" target="_blank" rel="noopener noreferrer">LuCI 页面</a>
          <a class="cbi-button" href="<%=restart_url%>">重启服务</a>
          <a class="cbi-button" href="<%=dsp.build_url('admin', 'system', 'ttyd', 'config')%>">配置页面</a>
        </div>
        <div class="webssh-fillgrid">
          <div class="webssh-fillcard">
            <h4>快捷命令</h4>
            <div class="webssh-quicklist">
              <a class="webssh-quickbtn" href="#" onclick="return copy_text('logread | tail -50');">
                <strong>复制最近日志命令</strong>
                <code>logread | tail -50</code>
              </a>
              <a class="webssh-quickbtn" href="#" onclick="return copy_text('ip route');">
                <strong>复制路由查看命令</strong>
                <code>ip route</code>
              </a>
              <a class="webssh-quickbtn" href="#" onclick="return copy_text('/etc/init.d/ttyd restart');">
                <strong>复制 ttyd 重启命令</strong>
                <code>/etc/init.d/ttyd restart</code>
              </a>
            </div>
          </div>
          <div class="webssh-fillcard">
            <h4>排障步骤</h4>
            <ul>
              <li>先点“重载终端”，等待 5 秒看状态变化。</li>
              <li>再点“全屏打开”，排除 iframe 本身的限制。</li>
              <li>最后复制 SSH 命令，直接进终端排查服务。</li>
            </ul>
          </div>
        </div>
      </div>
      <div class="webssh-card">
        <h3>状态概览</h3>
        <div class="webssh-kvlist">
          <div class="webssh-kv"><span>运行状态</span><strong><%=runtime_label%></strong></div>
          <div class="webssh-kv"><span>安装状态</span><strong><%=installed and '已安装' or '未安装'%></strong></div>
          <div class="webssh-kv"><span>绑定接口</span><strong><%=bind_iface_label%></strong></div>
          <div class="webssh-kv"><span>客户端上限</span><strong><%=client_limit_label%></strong></div>
          <div class="webssh-kv"><span>进程检查</span><strong><%=proc_check_label%></strong></div>
          <div class="webssh-kv"><span>端口检查</span><strong><%=port_check_label%></strong></div>
          <div class="webssh-kv"><span>接口检查</span><strong><%=iface_check_label%></strong></div>
          <div class="webssh-kv"><span>自检结果</span><strong><%=self_check_label%></strong></div>
        </div>
        <% if listen_line ~= "" then %>
        <div class="webssh-note">监听详情</div>
        <div class="webssh-command"><code><%=listen_line%></code></div>
        <% end %>
        <div class="webssh-note">SSH 命令</div>
        <div class="webssh-command"><code><%=ssh_cmd%></code></div>
        <div class="webssh-footer">首次打开后会直接进入 <code>/bin/sh --login</code>，适合临时维护和救援操作。</div>
      </div>
    </div>
    <div class="webssh-card webssh-terminal">
      <div class="webssh-head" style="align-items:center;">
        <div>
          <h3 style="margin:0;font-size:15px;color:#0f172a;">内嵌终端</h3>
          <div class="webssh-note" style="margin-top:6px;">可以直接在卡片里操作 ttyd，不用再新开窗口。</div>
        </div>
        <% if installed then %>
        <div class="webssh-actions">
          <a class="cbi-button cbi-button-apply" href="<%=ttyd_url%>" target="_blank" rel="noopener noreferrer">全屏打开</a>
          <a class="cbi-button cbi-button-reset" href="#" onclick="reload_terminal_frame(); return false;">重载终端</a>
          <a class="cbi-button cbi-button-reset" href="#" onclick="return copy_text('<%=ttyd_url%>');">复制地址</a>
        </div>
        <% end %>
      </div>
      <% if installed then %>
      <div class="webssh-toolbar">
        <div class="webssh-toolbar-left">
          <span id="webssh-frame-state" class="webssh-chip gray">终端加载中</span>
          <span class="webssh-note" style="margin-top:0;">若超过 5 秒仍空白，会显示失败提示。</span>
        </div>
        <div class="webssh-toolbar-right">
          <button class="webssh-mini-btn" type="button" data-height="480" onclick="set_terminal_height(480, this)">紧凑</button>
          <button class="webssh-mini-btn active" type="button" data-height="640" onclick="set_terminal_height(640, this)">标准</button>
          <button class="webssh-mini-btn" type="button" data-height="820" onclick="set_terminal_height(820, this)">扩展</button>
        </div>
      </div>
      <div class="webssh-focus-banner">
        <span>如果能看到终端但打不了字，先点一次“激活键盘”，再点击终端区域。</span>
        <button class="webssh-mini-btn" type="button" onclick="return focus_terminal_frame(this)">激活键盘</button>
      </div>
      <div id="webssh-frame-hint" class="webssh-alert">内嵌终端未正常显示，可能是浏览器拦截 iframe、ttyd 正在重启，或当前会话尚未完成握手。请点击“全屏打开”继续使用。</div>
      <iframe id="webssh-frame" src="<%=ttyd_url%>" title="ttyd Web SSH" loading="lazy" allow="clipboard-read; clipboard-write" tabindex="0" class="webssh-terminal-frame"></iframe>
      <div class="webssh-footer">如果这里仍然空白，优先使用“全屏打开”，通常更稳定。</div>
      <% else %>
      <div class="webssh-note">ttyd 还没安装，请先运行总脚本的 3 号选项。</div>
      <% end %>
    </div>
    <div class="webssh-tiprow">
      <div class="webssh-tip">1. 点击“打开终端”进入 shell。</div>
      <div class="webssh-tip">2. 如果内嵌终端空白，请先试“重载终端”，再试“全屏打开”。</div>
      <div class="webssh-tip">3. 终端高度可以在紧凑、标准、扩展之间切换，并会记住你的选择。</div>
    </div>
  </div>
</div>
<script type="text/javascript">//<![CDATA[
function copy_text(value)
{
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).catch(function(){ window.prompt('复制内容', value); });
    } else {
        window.prompt('复制内容', value);
    }
    return false;
}

function set_terminal_height(height, el)
{
    var frame = document.getElementById('webssh-frame');
    var buttons = document.querySelectorAll('.webssh-mini-btn[data-height]');

    if (frame)
        frame.style.height = String(height) + 'px';

    if (window.localStorage)
        localStorage.setItem('webssh-terminal-height', String(height));

    for (var i = 0; i < buttons.length; i++)
        buttons[i].classList.remove('active');

    if (el)
        el.classList.add('active');

    return false;
}

function restore_terminal_height()
{
    if (!window.localStorage)
        return;

    var saved = localStorage.getItem('webssh-terminal-height');
    if (!saved)
        return;

    var button = document.querySelector('.webssh-mini-btn[data-height="' + saved + '"]');
    if (button)
        set_terminal_height(parseInt(saved, 10), button);
}

function reload_terminal_frame()
{
    var frame = document.getElementById('webssh-frame');
    var state = document.getElementById('webssh-frame-state');
    var hint = document.getElementById('webssh-frame-hint');

    if (!frame)
        return false;

    if (state) {
        state.textContent = '终端重新加载中';
        state.className = 'webssh-chip gray';
    }

    if (hint)
        hint.style.display = 'none';

    frame.src = frame.src;
    return false;
}

function focus_terminal_frame(el)
{
    var frame = document.getElementById('webssh-frame');
    if (!frame)
        return false;

    try {
        frame.setAttribute('tabindex', '0');
        frame.focus();
    } catch(e) {}

    try {
        if (frame.contentWindow && frame.contentWindow.focus)
            frame.contentWindow.focus();
    } catch(e) {}

    if (el) {
        el.classList.add('active');
        window.setTimeout(function(){ el.classList.remove('active'); }, 1200);
    }

    return false;
}

(function(){
    var frame = document.getElementById('webssh-frame');
    var state = document.getElementById('webssh-frame-state');
    var hint = document.getElementById('webssh-frame-hint');
    var stamp = document.getElementById('webssh-updated');
    var loaded = false;

    if (stamp) {
        var now = new Date();
        stamp.textContent = '更新 ' + now.getHours().toString().padStart(2, '0') + ':' + now.getMinutes().toString().padStart(2, '0') + ':' + now.getSeconds().toString().padStart(2, '0');
    }

    restore_terminal_height();

    if (!frame || !state || !hint)
        return;

    frame.addEventListener('load', function(){
        loaded = true;
        state.textContent = '终端已加载';
        state.className = 'webssh-chip';
        hint.style.display = 'none';
        window.setTimeout(function(){ focus_terminal_frame(); }, 120);
    });

    frame.addEventListener('mouseenter', function(){ focus_terminal_frame(); });
    frame.addEventListener('click', function(){ focus_terminal_frame(); });

    window.setTimeout(function(){
        if (loaded)
            return;
        state.textContent = '终端可能未加载';
        state.className = 'webssh-chip off';
        hint.style.display = 'block';
    }, 5000);
})();
//]]></script>
<%+footer%>
EOF
}

patch_appcenter_shortcut() {
    template_file="/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm"
    [ -f "$template_file" ] || return 0

    if grep -q 'app_list.result.applist.unshift({name:"Web SSH"' "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-entry.htm"
        awk '
            {
                if ($0 ~ /app_list\.result\.applist\.unshift\(\{name:"Web SSH"/) {
                    print "    app_list.result.applist.unshift({name:\"Web SSH\", version:\"ttyd 1.7.7\", des:\"浏览器 SSH 终端\", icon:\"app_default.png\", open:1, has_luci:1, status:1, luci_module_route:\"nradioadv/system/webssh\"});"
                    next
                }
                print
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    else
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-entry.htm"
        awk '
            BEGIN { done = 0 }
            {
                print
                if (!done && $0 ~ /^    var app_list = /) {
                    print "    if (!app_list.result) app_list.result = {applist: []};"
                    print "    if (!app_list.result.applist) app_list.result.applist = [];"
                    print "    app_list.result.applist.unshift({name:\"Web SSH\", version:\"ttyd 1.7.7\", des:\"浏览器 SSH 终端\", icon:\"app_default.png\", open:1, has_luci:1, status:1, luci_module_route:\"nradioadv/system/webssh\"});"
                    done = 1
                }
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if ! grep -q "frame.src.indexOf('/nradioadv/system/webssh')" "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-iframe.htm"
        awk '
            {
                if ($0 ~ /frame\.src\.indexOf\('\''\/admin\/services\/openclash'\''\)/) {
                    print "            if (frame.src.indexOf('\''/admin/services/openclash'\'') === -1 && frame.src.indexOf('\''/admin/services/AdGuardHome'\'') === -1 && frame.src.indexOf('\''/nradioadv/system/openvpnfull'\'') === -1 && frame.src.indexOf('\''/nradioadv/system/webssh'\'') === -1)"
                    next
                }
                print
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if ! grep -q "tabindex='0' allow='clipboard-read; clipboard-write'" "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-iframe-attrs.htm"
        sed "s|return \"<iframe id='sub_frame' src='\" + get_app_route_url(route) + \"' name='subpage'></iframe>\";|return \"<iframe id='sub_frame' src='\" + get_app_route_url(route) + \"' name='subpage' tabindex='0' allow='clipboard-read; clipboard-write'></iframe>\";|" "$template_file" | sed "s|return \"<iframe id='sub_frame' name='subpage'></iframe>\";|return \"<iframe id='sub_frame' name='subpage' tabindex='0' allow='clipboard-read; clipboard-write'></iframe>\";|" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if ! grep -q 'function is_webssh_route(route)' "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-webssh-route.htm"
        awk '
            BEGIN { in_fn = 0; done = 0 }
            {
                print
                if (!done && $0 ~ /^    function is_adguardhome_route\(route\)\{$/) {
                    in_fn = 1
                    next
                }
                if (in_fn && $0 ~ /^    }$/) {
                    print "    function is_webssh_route(route){"
                    print "        return route && route.indexOf(\"nradioadv/system/webssh\") === 0;"
                    print "    }"
                    print "    function enable_webssh_iframe_input(){"
                    print "        try {"
                    print "            var frame = document.getElementById(\"sub_frame\");"
                    print "            if (!frame || !frame.src || frame.src.indexOf(\"/nradioadv/system/webssh\") === -1)"
                    print "                return;"
                    print ""
                    print "            $(document).off(\"focusin.bs.modal\");"
                    print "            $(\".modal.app_frame.in\").attr(\"tabindex\", \"-1\");"
                    print "            $(frame).attr(\"tabindex\", \"0\");"
                    print ""
                    print "            frame.focus();"
                    print "            if (frame.contentWindow && frame.contentWindow.focus)"
                    print "                frame.contentWindow.focus();"
                    print "        }"
                    print "        catch(e) {}"
                    print "    }"
                    in_fn = 0
                    done = 1
                }
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if ! grep -q "app_name == 'Web SSH' && action == 'uninstall'" "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-webssh-uninstall.htm"
        awk '
            BEGIN { inserted = 0 }
            {
                print
                if (!inserted && $0 ~ /^        var info_msg = \"\";$/) {
                    print "        if (app_name == '\''Web SSH'\'' && action == '\''uninstall'\'') {"
                    print "            window.location.href = '\''<%=controller%>nradioadv/system/webssh/uninstall'\'';"
                    print "            return;"
                    print "        }"
                    print ""
                    inserted = 1
                }
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if grep -q 'window.location.href = get_app_route_url(route);' "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-webssh-direct-open.htm"
        awk '
            BEGIN { skip = 0 }
            {
                if (!skip && $0 ~ /^        if \(is_webssh_route\(route\)\) \{$/) {
                    skip = 1
                    next
                }
                if (skip) {
                    if ($0 ~ /^        }$/) {
                        skip = 0
                    }
                    next
                }
                print
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if ! grep -q 'closeByKeyboard: false,' "$template_file" || ! grep -q 'modal_data.enforceFocus = function(){};' "$template_file"; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-webssh-dialog.htm"
        awk '
            BEGIN {
                in_callback = 0
                in_dialog = 0
                inserted_close = 0
                inserted_focus = 0
            }
            {
                if ($0 ~ /^    function callback\(id,route\)\{$/)
                    in_callback = 1
                if (in_callback && $0 ~ /^    function app_action\(/) {
                    in_callback = 0
                    in_dialog = 0
                }
                if (in_callback && $0 ~ /^        sub_dialogDeal = BootstrapDialog\.show\(\{$/)
                    in_dialog = 1

                print

                if (in_dialog && !inserted_close && $0 ~ /^            closeByBackdrop: true,$/) {
                    print "            closeByKeyboard: false,"
                    inserted_close = 1
                }

                if (in_dialog && !inserted_focus && $0 ~ /^            onshown:function\(\)\{$/) {
                    print "                try {"
                    print "                    var modal = sub_dialogDeal && sub_dialogDeal.getModal ? sub_dialogDeal.getModal() : $(\".modal.app_frame.in\");"
                    print "                    var modal_data = modal && modal.data ? modal.data(\"bs.modal\") : null;"
                    print "                    if (modal_data)"
                    print "                        modal_data.enforceFocus = function(){};"
                    print "                    $(document).off(\"focusin.bs.modal\");"
                    print "                    $(modal).attr(\"tabindex\", \"-1\");"
                    print "                }"
                    print "                catch(e) {}"
                    print ""
                    inserted_focus = 1
                }

                if (in_dialog && $0 ~ /^        \}\);$/)
                    in_dialog = 0
            }
        ' "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi

    if grep -Eq '\$\(\.modal\.app_frame\.in\)|modal\.data\(bs\.modal\)|\$\(document\)\.off\(focusin\.bs\.modal\)|\$\(modal\)\.attr\(tabindex, -1\)' "$template_file" 2>/dev/null; then
        backup_file "$template_file"
        tmp_file="$WORKDIR/appcenter-webssh-jsfix.htm"
        sed -e 's/$(\.modal\.app_frame\.in)/$(".modal.app_frame.in")/g' \
            -e 's/modal\.data(bs\.modal)/modal.data("bs.modal")/g' \
            -e 's/$(document)\.off(focusin\.bs\.modal)/$(document).off("focusin.bs.modal")/g' \
            -e 's/$(modal)\.attr(tabindex, -1)/$(modal).attr("tabindex", "-1")/g' \
            "$template_file" > "$tmp_file" && mv "$tmp_file" "$template_file"
    fi
}

restart_services() {
    rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
    if [ -x /etc/init.d/ttyd ]; then
        /etc/init.d/ttyd enable >/dev/null 2>&1 || true
        /etc/init.d/ttyd stop >/dev/null 2>&1 || true
        killall ttyd >/dev/null 2>&1 || true
        sleep 1
        /etc/init.d/ttyd start >/dev/null 2>&1 || true
    fi
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
}

show_summary() {
    lan_ip="$(get_lan_ip)"
    [ -n "$lan_ip" ] || lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
    log "done"
    log "Web SSH page: /cgi-bin/luci/nradioadv/system/appcenter/webssh"
    log "LuCI ttyd:    /cgi-bin/luci/admin/system/ttyd/overview"
    log "Direct ttyd:  http://$lan_ip:7681/"
}

install_all() {
    install_ttyd_binary
    install_luci_ttyd
    install_webssh_wrapper
    patch_appcenter_shortcut
    restart_services
}

main() {
    ensure_root
    ensure_workdir

    choice="${1:-}"
    if [ -z "$choice" ]; then
        printf '%s\n' "$APP_NAME"
        printf '1. 安装 ttyd Web SSH\n'
        printf '请选择 1: '
        read -r choice || die "input cancelled"
    fi

    case "$choice" in
        1) install_all ;;
        *) die "仅支持选项 1" ;;
    esac

    show_summary
}

main "$@"
__TTYD_HELPER__
    chmod 700 "$helper"
    log "running embedded ttyd/Web SSH installer..."
    sh "$helper" 1 || die "ttyd/Web SSH install failed"
}

main_menu() {
    require_root
    printf '%s\n' "$SCRIPT_TITLE"
    printf '%s\n' "$SCRIPT_SIGNATURE"
    printf '%s\n' "$SCRIPT_DISCLAIMER"
    printf '请选择要安装并接入应用商店的插件:\n'
    printf '1. OpenClash\n'
    printf '2. AdGuardHome\n'
    printf '3. ttyd / Web SSH\n'
    printf '4. OpenVPN\n'
    printf '5. OpenVPN 向导配置并运行\n'
    printf '6. OpenVPN 路由表向导\n'
    printf '请输入 1、2、3、4、5 或 6: '
    read -r choice

    case "$choice" in
        1)
            install_openclash
            ;;
        2)
            install_adguardhome
            ;;
        3)
            install_ttyd_webssh
            ;;
        4)
            install_openvpn
            ;;
        5)
            configure_openvpn_runtime
            ;;
        6)
            configure_openvpn_routes
            ;;
        *)
            die "invalid choice: $choice"
            ;;
    esac
}

main_menu
