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
WORKDIR="/tmp/nradio-plugin-fix.$$"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
OPENCLASH_BRANCH="${OPENCLASH_BRANCH:-master}"
OPENCLASH_MIRRORS="${OPENCLASH_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://fastly.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH}}"
ADGUARDHOME_VERSION="${ADGUARDHOME_VERSION:-1.8-9}"
ADGUARDHOME_IPK_URLS="${ADGUARDHOME_IPK_URLS:-https://ghproxy.net/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk https://mirror.ghproxy.com/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk https://gh-proxy.com/https://github.com/rufengsuixing/luci-app-adguardhome/releases/download/${ADGUARDHOME_VERSION}/luci-app-adguardhome_${ADGUARDHOME_VERSION}_all.ipk}"
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
        curl -C - -LfS --progress-bar --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" --retry "$DOWNLOAD_RETRY" --retry-delay 2 "$url" -o "$tmp_out"
    elif command -v wget >/dev/null 2>&1; then
        wget -c --no-check-certificate -T "$DOWNLOAD_MAX_TIME" -t "$DOWNLOAD_RETRY" -O "$tmp_out" "$url"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        printf 'note: uclient-fetch does not show full progress bar, downloading anyway...\n' >&2
        uclient-fetch -T "$DOWNLOAD_MAX_TIME" -q -O "$tmp_out" "$url"
    else
        die "need curl, wget or uclient-fetch"
    fi

    [ -s "$tmp_out" ] || return 1
    mv "$tmp_out" "$out"
}

download_from_mirrors() {
    rel="$1"
    out="$2"

    for base in $OPENCLASH_MIRRORS; do
        if download_file "$base/$rel" "$out"; then
            printf '%s\n' "$base"
            return 0
        fi
    done

    return 1
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
    {
        printf 'ROUTE_LAN_IF=%s\n' "$(shell_quote "$lan_if")"
        printf 'ROUTE_TUN_IF=%s\n' "$(shell_quote "$tun_if")"
        printf 'ROUTE_LAN_SUBNET=%s\n' "$(shell_quote "$lan_subnet")"
        printf 'ROUTE_TUN_SUBNET=%s\n' "$(shell_quote "$tun_subnet")"
        printf 'ROUTE_NAT=%s\n' "$(shell_quote "$route_nat_save")"
        printf 'ROUTE_FORWARD=%s\n' "$(shell_quote "$route_forward_save")"
        printf 'ROUTE_ENHANCED=%s\n' "$(shell_quote "$route_enhanced_save")"
    } > "$ROUTE_STATE_FILE"
    cp "$route_tmp" "$ROUTE_LIST_FILE" 2>/dev/null || true
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
    unset ROUTE_LAN_IF ROUTE_TUN_IF ROUTE_LAN_SUBNET ROUTE_TUN_SUBNET ROUTE_NAT ROUTE_FORWARD
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

set_appcenter_entry() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller="$5"
    route="$6"

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
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/infocd stop >/dev/null 2>&1 || true
    killall infocd infocd_consumer 2>/dev/null || true
    /etc/init.d/infocd start >/dev/null 2>&1 || true
    /etc/init.d/appcenter stop >/dev/null 2>&1 || true
    killall appcenter 2>/dev/null || true
    /etc/init.d/appcenter start >/dev/null 2>&1 || /etc/init.d/appcenter restart >/dev/null 2>&1 || true
    sleep 2
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
    patch_common_template
    refresh_luci_appcenter
    verify_appcenter_route "luci-app-openclash" "admin/services/openclash"
    verify_file_exists /usr/lib/lua/luci/controller/openclash.lua "OpenClash"
    verify_luci_route admin/services/openclash "OpenClash"
    verify_luci_route admin/services/openclash/settings "OpenClash"
    verify_luci_route admin/services/openclash/config-overwrite "OpenClash"
    verify_luci_route admin/services/openclash/config-subscribe "OpenClash"
    verify_luci_route admin/services/openclash/config "OpenClash"
    verify_luci_route admin/services/openclash/log "OpenClash"

    log "done"
    log "plugin:   OpenClash"
    log "version:  $oc_ver"
    log "route:    admin/services/openclash"
    log "note:     OpenClash 页面已展开；核心请在 OpenClash 页面里按需更新"
    log "next:     close appcenter popup, then press Ctrl+F5 and reopen OpenClash"
}

write_adguard_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/AdGuardHome
    cat > /usr/lib/lua/luci/controller/AdGuardHome.lua <<'EOF'
module("luci.controller.AdGuardHome",package.seeall)
local fs=require"nixio.fs"
local http=require"luci.http"
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
for cnt in rf:lines() do
b=string.match (cnt,"^[^#]*nameserver%s+([^%s]+)$")
if (b~=nil) then
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
e.running=luci.sys.call("pgrep "..binpath.." >/dev/null")==0
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
luci.sys.exec("kill $(pgrep /usr/share/AdGuardHome/update_core.sh) ; sh /usr/share/AdGuardHome/update_core.sh "..arg.." >/tmp/AdGuardHome_update.log 2>&1 &")
end
else
luci.sys.exec("sh /usr/share/AdGuardHome/update_core.sh "..arg.." >/tmp/AdGuardHome_update.log 2>&1 &")
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
local pkg_ver=luci.sys.exec("grep PKG_VERSION /usr/share/AdGuardHome/Makefile 2>/dev/null | awk -F := '{print $2}'")
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

fix_adguard_runtime_if_possible() {
    binpath="$(uci -q get AdGuardHome.AdGuardHome.binpath 2>/dev/null || true)"
    [ -n "$binpath" ] || binpath="/usr/bin/AdGuardHome/AdGuardHome"
    [ -x "$binpath" ] || return 0

    configpath="$(uci -q get AdGuardHome.AdGuardHome.configpath 2>/dev/null || true)"
    [ -n "$configpath" ] || configpath="/etc/AdGuardHome.yaml"
    workdir="$(uci -q get AdGuardHome.AdGuardHome.workdir 2>/dev/null || true)"
    [ -n "$workdir" ] || workdir="/usr/bin/AdGuardHome"
    template_yaml="/usr/share/AdGuardHome/AdGuardHome_template.yaml"

    if [ ! -s "$configpath" ] && [ -f "$template_yaml" ]; then
        mkdir -p "${configpath%/*}" "$workdir/data"
        dns_list="$(awk '/^[^#]*nameserver[[:space:]]+/ {print "  - "$2}' /tmp/resolv.conf.auto 2>/dev/null || true)"
        [ -n "$dns_list" ] || dns_list="$(printf '  - 223.5.5.5\n  - 119.29.29.29\n')"
        awk -v dns="$dns_list" '
            /^#bootstrap_dns$/ { print dns; next }
            /^#upstream_dns$/ { print dns; next }
            { print }
        ' "$template_yaml" > "$configpath"
    fi

    if [ -f "$configpath" ] && grep -q '^  session_ttl: 0s$' "$configpath"; then
        sed -i 's/^  session_ttl: 0s$/  session_ttl: 720h/' "$configpath"
    fi

    if [ -s "$configpath" ] && "$binpath" -c "$configpath" --check-config >/tmp/AdGuardHometest.log 2>&1; then
        /etc/init.d/AdGuardHome enable >/dev/null 2>&1 || true
        /etc/init.d/AdGuardHome restart >/dev/null 2>&1 || /etc/init.d/AdGuardHome start >/dev/null 2>&1 || true
    fi
}

set_init_start_order() {
    init_script="$1"
    start_order="$2"

    [ -f "$init_script" ] || return 0
    if ! grep -q "^START=$start_order$" "$init_script"; then
        backup_file "$init_script"
        sed -i "s/^START=.*/START=$start_order/" "$init_script"
    fi
    "$init_script" disable >/dev/null 2>&1 || true
    "$init_script" enable >/dev/null 2>&1 || true
}

ensure_plugin_autostart_order() {
    set_init_start_order /etc/init.d/openvpn 90
    set_init_start_order /etc/init.d/openclash 99
    set_init_start_order /etc/init.d/AdGuardHome 105

    if [ -f /etc/config/openclash ]; then
        uci set openclash.config.enable='1' >/dev/null 2>&1 || true
        uci commit openclash >/dev/null 2>&1 || true
    fi

    if [ -f /etc/config/AdGuardHome ]; then
        uci set AdGuardHome.AdGuardHome.enabled='1' >/dev/null 2>&1 || true
        uci commit AdGuardHome >/dev/null 2>&1 || true
    fi
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
    fix_adguard_runtime_if_possible
    verify_appcenter_route "luci-app-adguardhome" "admin/services/AdGuardHome"
    verify_file_exists /usr/lib/lua/luci/controller/AdGuardHome.lua "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/base "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/manual "AdGuardHome"
    verify_luci_route admin/services/AdGuardHome/log "AdGuardHome"

    log "done"
    log "plugin:   AdGuardHome"
    log "version:  $adg_ver"
    log "route:    admin/services/AdGuardHome"
    if [ -x /usr/bin/AdGuardHome/AdGuardHome ]; then
        log "note:     core present; config/start checked"
    else
        log "note:     LuCI 已装好；核心请在 AdGuardHome 页面里更新后再启动"
    fi
    log "next:     close appcenter popup, then press Ctrl+F5 and reopen AdGuardHome"
}

write_openvpn_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller/nradio_adv /usr/lib/lua/luci/view/nradio_adv

    cat > /usr/lib/lua/luci/controller/nradio_adv/openvpn_full.lua <<'EOF'
module("luci.controller.nradio_adv.openvpn_full", package.seeall)
function index()
    local page = entry({"nradioadv", "system", "openvpnfull"}, template("nradio_adv/openvpn_full"), _("OpenVPN"), 94)
    page.show = true
    entry({"nradioadv", "system", "openvpnfull", "restart"}, call("restart"), nil).leaf = true
end
function restart()
    local http = require "luci.http"
    os.execute("( /etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn_client restart >/dev/null 2>&1 ) &")
    http.redirect(luci.dispatcher.build_url("nradioadv", "system", "openvpnfull"))
end
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
local rt = cmd("ip route | grep -E '11\\.1|192\\.168\\.[239]\\.0' 2>/dev/null")
local log = cmd("tail -40 /tmp/openvpn-client.log 2>/dev/null || logread 2>/dev/null | grep -i openvpn | tail -40")
local cfg = cmd("sed -n '1,160p' /etc/openvpn/client.ovpn 2>/dev/null")
local tun_ip = tun:match("inet%s+([%d%.]+/%d+)") or "-"
local connected = (((svc:match("running")) or ps ~= "") and tun:match("inet ")) and true or false
local mode = ps_std ~= "" and "Standard UCI" or (ps_legacy ~= "" and "Legacy client.ovpn" or "Stopped")
local route_list = {}
for line in rt:gmatch("[^\n]+") do
    route_list[#route_list + 1] = line
end
local route_count = #route_list

local function state_text(ok)
    return ok and "OK" or "FAIL"
end

local function state_class(ok)
    return ok and "vpn-badge-ok" or "vpn-badge-bad"
end
%>
<style>
    .vpn-map { max-width: 1080px; }
    .vpn-hero { display: flex; justify-content: space-between; align-items: center; gap: 16px; margin-bottom: 18px; padding: 18px 20px; border: 1px solid #e7eaee; border-radius: 12px; background: linear-gradient(135deg, #f8fbff 0%, #ffffff 100%); }
    .vpn-hero h2 { margin: 0 0 6px; }
    .vpn-sub { margin: 0; color: #68707a; }
    .vpn-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; margin-bottom: 18px; }
    .vpn-card { padding: 16px 18px; border: 1px solid #e7eaee; border-radius: 12px; background: #fff; }
    .vpn-card-title { margin-bottom: 12px; font-weight: 700; font-size: 15px; }
    .vpn-kv { display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid #f1f3f5; }
    .vpn-kv:last-child { border-bottom: 0; padding-bottom: 0; }
    .vpn-kv span:first-child { color: #68707a; }
    .vpn-badge-ok, .vpn-badge-bad { display: inline-block; min-width: 54px; padding: 2px 10px; border-radius: 999px; text-align: center; font-size: 12px; font-weight: 700; }
    .vpn-badge-ok { color: #166534; background: #dcfce7; }
    .vpn-badge-bad { color: #991b1b; background: #fee2e2; }
    .vpn-route-list { display: flex; flex-direction: column; gap: 10px; }
    .vpn-route-item { padding: 12px; border: 1px solid #eef1f4; border-radius: 10px; background: #fafbfc; font-family: monospace; word-break: break-word; }
    .vpn-detail { margin-top: 12px; border: 1px solid #e7eaee; border-radius: 12px; background: #fff; overflow: hidden; }
    .vpn-detail summary { padding: 12px 16px; cursor: pointer; font-weight: 700; background: #fafbfc; }
    .vpn-detail pre { margin: 0; padding: 14px 16px; white-space: pre-wrap; word-break: break-word; border-top: 1px solid #eef1f4; background: #fff; }
</style>
<div class="cbi-map vpn-map">
  <div class="vpn-hero">
    <div>
      <h2>OpenVPN 完整版</h2>
      <p class="vpn-sub">OEM 应用商店兼容页，已适配标准 UCI 启动方式。</p>
    </div>
    <form method="post" action="<%=luci.dispatcher.build_url('nradioadv','system','openvpnfull','restart')%>">
      <input class="cbi-button cbi-button-apply" type="submit" value="重连 OpenVPN" />
    </form>
  </div>
  <div class="vpn-grid">
    <div class="vpn-card">
      <div class="vpn-card-title">运行状态</div>
      <div class="vpn-kv"><span>连接</span><strong class="<%=state_class(connected)%>"><%= connected and 'Connected' or 'Disconnected' %></strong></div>
      <div class="vpn-kv"><span>模式</span><strong><%=esc(mode)%></strong></div>
      <div class="vpn-kv"><span>服务</span><strong><%=esc(svc ~= '' and svc or 'unknown')%></strong></div>
      <div class="vpn-kv"><span>隧道 IP</span><strong><%=esc(tun_ip)%></strong></div>
    </div>
    <div class="vpn-card">
      <div class="vpn-card-title">隧道路由</div>
      <div class="vpn-kv"><span>数量</span><strong><%=route_count%></strong></div>
      <div class="vpn-route-list">
      <% if route_count > 0 then %>
      <% for _, item in ipairs(route_list) do %>
        <div class="vpn-route-item"><%=esc(item)%></div>
      <% end %>
      <% else %>
        <div class="vpn-route-item">no route detected</div>
      <% end %>
      </div>
    </div>
  </div>
  <details class="vpn-detail" open><summary>进程信息</summary><pre><%=esc(ps ~= '' and ps or 'no process')%></pre></details>
  <details class="vpn-detail"><summary>隧道信息</summary><pre><%=esc(tun)%></pre></details>
  <details class="vpn-detail"><summary>路由信息</summary><pre><%=esc(rt ~= '' and rt or 'no route')%></pre></details>
  <details class="vpn-detail"><summary>客户端配置</summary><pre><%=esc(cfg ~= '' and cfg or 'no config')%></pre></details>
  <details class="vpn-detail"><summary>运行日志</summary><pre><%=esc(log ~= '' and log or 'no log')%></pre></details>
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
        /etc/init.d/openvpn enable >/dev/null 2>&1 || true
        /etc/init.d/openvpn restart >/tmp/openvpn-runtime-fix.log 2>&1 || true
        sleep 10
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

    cat > "$ovpn_dst" <<EOF
client
dev tun
proto $ovpn_proto
remote $ovpn_server $ovpn_port
resolv-retry infinite
nobind
persist-key
persist-tun
tun-mtu $ovpn_mtu
status /var/run/openvpn.custom_config.status 10
log /tmp/openvpn-client.log
verb 3
EOF

    if [ "$ovpn_server_verify" = 'strict' ]; then
        cat >> "$ovpn_dst" <<'EOF'
remote-cert-tls server
EOF
    fi

    if [ "$ovpn_verify_cn" = '1' ]; then
        cat >> "$ovpn_dst" <<EOF
verify-x509-name $ovpn_server_cn name
EOF
    fi

    if [ "$ovpn_auth" = '1' ]; then
        cat > "$auth_dst" <<EOF
$ovpn_user
$ovpn_pass
EOF
        chmod 600 "$auth_dst"
        cat >> "$ovpn_dst" <<EOF
auth-user-pass $auth_dst
auth-nocache
EOF
    else
        rm -f "$auth_dst"
    fi

    if [ -n "$ovpn_cipher" ]; then
        cat >> "$ovpn_dst" <<EOF
cipher $ovpn_cipher
data-ciphers $ovpn_cipher
data-ciphers-fallback $ovpn_cipher
EOF
    fi

    if [ -n "$ovpn_auth_digest" ]; then
        cat >> "$ovpn_dst" <<EOF
auth $ovpn_auth_digest
EOF
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

    openvpn_bin="$(command -v openvpn 2>/dev/null || true)"
    [ -n "$openvpn_bin" ] || openvpn_bin='/usr/sbin/openvpn'
    [ -x "$openvpn_bin" ] || die "OpenVPN runtime failed: openvpn binary missing"

    "$openvpn_bin" --config "$ovpn_dst" --daemon --writepid /var/run/openvpn.custom_config.pid --log /tmp/openvpn-client.log --status /var/run/openvpn.custom_config.status 5 --verb 4 >/tmp/openvpn-runtime-fix.log 2>&1 || true
    sleep 12

    ovpn_status="stopped"
    [ -f /var/run/openvpn.custom_config.pid ] && ovpn_status="running"
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
        if [ "$route_enhanced" = '1' ] && [ -n "$tun_subnet" ]; then
            tun_supernet="$(derive_supernet16_from_cidr "$tun_subnet" 2>/dev/null || true)"
            printf '%s\n' 'TUN_SUPERNET="'"$tun_supernet"'"'
        else
            printf '%s\n' 'TUN_SUPERNET=""'
        fi
        printf '%s\n' ''
        printf '%s\n' 'apply_routes() {'
        printf '%s\n' '    [ -d "/sys/class/net/$TUN_IF" ] || exit 0'
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
        while IFS='|' read -r subnet gw; do
            [ -n "$subnet" ] || continue
            printf '%s\n' "    ip route replace \"$subnet\" via \"$gw\" dev \"\$TUN_IF\" 2>/dev/null"
            if [ "$route_nat" = '1' ]; then
                printf '%s\n' "    iptables -t nat -C POSTROUTING -s \"\$LAN_SUBNET\" -d \"$subnet\" -o \"\$TUN_IF\" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s \"\$LAN_SUBNET\" -d \"$subnet\" -o \"\$TUN_IF\" -j MASQUERADE"
            fi
            if [ "$route_forward" = '1' ]; then
                printf '%s\n' "    iptables -C FORWARD -s \"$subnet\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -s \"$subnet\" -d \"\$LAN_SUBNET\" -i \"\$TUN_IF\" -o \"\$LAN_IF\" -j ACCEPT"
                printf '%s\n' "    iptables -C FORWARD -d \"$subnet\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -d \"$subnet\" -i \"\$LAN_IF\" -o \"\$TUN_IF\" -j ACCEPT"
            fi
        done < "$route_tmp"
        if [ "$route_enhanced" = '1' ]; then
            pri=96
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
        if [ -n "$tun_subnet" ]; then
            ip route | grep -q "^$tun_subnet dev $tun_if" || die "route apply failed: missing tunnel subnet $tun_subnet dev $tun_if"
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

main_menu() {
    require_root
    printf '%s\n' "$SCRIPT_TITLE"
    printf '%s\n' "$SCRIPT_SIGNATURE"
    printf '%s\n' "$SCRIPT_DISCLAIMER"
    printf '请选择要安装并接入应用商店的插件:\n'
    printf '1. OpenClash\n'
    printf '2. AdGuardHome\n'
    printf '3. OpenVPN\n'
    printf '4. OpenVPN 向导配置并运行\n'
    printf '5. OpenVPN 路由表向导\n'
    printf '请输入 1、2、3、4 或 5: '
    read -r choice

    case "$choice" in
        1)
            install_openclash
            ;;
        2)
            install_adguardhome
            ;;
        3)
            install_openvpn
            ;;
        4)
            configure_openvpn_runtime
            ;;
        5)
            configure_openvpn_routes
            ;;
        *)
            die "invalid choice: $choice"
            ;;
    esac
}

main_menu
