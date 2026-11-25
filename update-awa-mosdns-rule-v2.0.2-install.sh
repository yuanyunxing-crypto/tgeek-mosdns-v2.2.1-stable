#!/bin/sh
# TGEEK advertising rules updater 2.0.2
set -eu
umask 077
DIR=/etc/mosdns/rule
LIVE=/var/etc/mosdns.json
EXCLUDE="$DIR/tgeek-youtube-exclude.txt"
[ "${1:-}" != --version ] || { echo "TGEEK Ads Updater 2.0.2"; exit 0; }
LOCK=/var/lock/tgeek-mosdns-v21.lock
case "${1:-update}" in
    install)
        DST=/usr/bin/update-awa-mosdns-rule.sh
        [ "$(id -u)" = 0 ] || { echo "ERROR: 请使用 root 安装"; exit 1; }
        sh -n "$0" || exit 1
        mkdir -p /var/lock
        mkdir "$LOCK" 2>/dev/null || { echo "ERROR: 已有 TGEEK 更新任务"; exit 1; }
        TMP="$DST.install.$$"
        trap 'rm -f "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT
        trap 'exit 1' HUP INT TERM
        if [ -f "$DST" ]; then
            BAK="$DST.bak-$(date +%Y%m%d-%H%M%S)-$$"
            cp -p "$DST" "$BAK"
            echo "旧版本备份：$BAK"
        fi
        cp "$0" "$TMP"
        chmod 755 "$TMP"
        mv -f "$TMP" "$DST"
        "$DST" --version
        echo "安装成功：$DST"
        echo "原有定时任务保持不变；首次更新请执行 $DST update"
        exit 0
        ;;
    update) ;;
    *) echo "用法：$0 [install|update|--version]"; exit 2 ;;
esac
LOG=/var/log/awa-mosdns-update.log
WORK=
BACK=
CHANGED=
ACTIVE=0
FAILED=0
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
cleanup(){
    rc=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$ACTIVE" = 1 ]; then
        log "恢复更新前规则：$BACK"
        ok=1
        for f in $CHANGED; do
            cp -p "$BACK/$f" "$DIR/$f.restore" && mv -f "$DIR/$f.restore" "$DIR/$f" || ok=0
        done
        /etc/init.d/mosdns restart || ok=0
        [ "$ok" = 1 ] || log "ERROR: 回滚未完全成功，请检查备份"
        rc=1
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    rmdir "$LOCK" 2>/dev/null
    exit "$rc"
}
die(){ log "ERROR: $*"; exit 1; }
mkdir -p /var/lock /var/log
for cmd in curl jsonfilter nslookup awk; do command -v "$cmd" >/dev/null || die "缺少 $cmd"; done
mkdir "$LOCK" 2>/dev/null || die "已有 TGEEK 更新任务"
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
WORK="$(mktemp -d /tmp/tgeek-ads.XXXXXX)"
[ "$(uci -q get mosdns.config.listen_port)" = 53 ] || die "本版健康检测仅支持 53 端口"
[ "$(uci -q get mosdns.config.configfile)" = "$LIVE" ] || die "不是 UCI 自动生成模式"
refs="$(jsonfilter -i "$LIVE" -e '@.plugins[@.tag="adlist"].args.files[*]')"
health(){
    pidof mosdns >/dev/null || return 1
    nslookup -type=A baidu.com 127.0.0.1 2>/dev/null | awk '
      /^Name:/ {answer=1}
      answer && /^Address([[:space:]]+[0-9]+)?:/ {
        ip=$NF; if(ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip!="0.0.0.0" && ip!="127.0.0.1") ok=1
      } END{exit !ok}' || return 1
    nslookup -type=A ad.doubleclick.net 127.0.0.1 2>/dev/null |
      grep -Eq '^Address([[:space:]]+[0-9]+)?:[[:space:]]+0\.0\.0\.0[[:space:]]*$'
}
# Exact-domain exclusions; mandatory baseline cannot be removed by local edits.
prepare_exclusions(){
    printf '%s\n' manifest.googlevideo.com > "$WORK/exclude.raw" || return 1
    if [ -e "$EXCLUDE" ]; then
        [ -f "$EXCLUDE" ] && [ -r "$EXCLUDE" ] || return 1
        awk '
          {sub(/\r$/, ""); sub(/[[:space:]]+#.*/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")}
          /^($|#)/ {next}
          {h=tolower($0); sub(/^full:/,"",h); sub(/\.$/,"",h);
           if(h ~ /^[a-z0-9-]+(\.[a-z0-9-]+)+$/ && h !~ /^[0-9.]+$/ && length(h)<=253) print h;
           else {bad++; printf "无效排除域名，第 %d 行\n", NR > "/dev/stderr"}}
          END{if(bad)exit 1}
        ' "$EXCLUDE" >> "$WORK/exclude.raw" || return 1
    fi
    LC_ALL=C sort -u "$WORK/exclude.raw" > "$WORK/exclude" || return 1
}
filter_youtube(){
    awk 'FNR==NR {skip["full:" $0]=1; next} !($0 in skip)' \
        "$WORK/exclude" "$1" > "$WORK/youtube.filtered" || return 1
    log "YouTube 安全排除：移除 $(($(wc -l < "$1")-$(wc -l < "$WORK/youtube.filtered"))) 条"
    [ "$(wc -l < "$WORK/youtube.filtered")" -ge 100 ] || return 1
    mv -f "$WORK/youtube.filtered" "$1" || return 1
}
manifest_health(){
    nslookup -type=A manifest.googlevideo.com 127.0.0.1 2>/dev/null | awk '
      /^Name:/ {answer=1}
      answer && /^Address([[:space:]]+[0-9]+)?:/ {
        ip=$NF; if(ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip!="0.0.0.0" && ip!="127.0.0.1") ok=1
        if(ip=="0.0.0.0") blocked=1
      } END{exit !(ok && !blocked)}'
}
validate(){
    kind="$1"
    src="$2"
    dest="$3"
    [ -s "$src" ] || return 1
    if [ "$kind" = awa ]; then
        if ! awk '
          {sub(/\r$/," "); sub(/^[ \t]+/,""); sub(/[ \t]+$/,"")}
          /^($|#)/ {print; next}
          /^(full|domain):[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/ {n++; print; next}
          /^keyword:[A-Za-z0-9_.-]+$/ {n++; print; next}
          {bad++; if(bad<=10) printf "无效秋风规则，第 %d 行: %s\n", NR, substr($0,1,160) > "/dev/stderr"}
          END{if(n<100 || bad) {printf "秋风校验: 有效=%d 异常=%d\n",n,bad > "/dev/stderr"; exit 1}}
        ' "$src" > "$dest"; then
            log "秋风格式校验失败"
            return 1
        fi
    else
        awk '
          {sub(/\r$/,""); sub(/^[[:space:]]+/,"")}
          /^($|#)/ {next}
          {sub(/[[:space:]]+#.*/,""); n=split($0,a,/[[:space:]]+/);
           h=tolower(a[1]); if(h=="0.0.0.0"||h=="127.0.0.1"||h=="::1") h=tolower(a[2]);
           if(h ~ /^[a-z0-9-]+(\.[a-z0-9-]+)+$/ && h !~ /^[0-9.]+$/ && length(h)<=253) print "full:" h;
           else bad++}
          END{if(bad)exit 1}
        ' "$src" > "$WORK/youtube.unsorted" || return 1
        LC_ALL=C sort -u "$WORK/youtube.unsorted" > "$dest" || return 1
        [ "$(wc -l < "$dest")" -ge 100 ] || return 1
        filter_youtube "$dest" || return 1
    fi
}
stage(){
    file="$1"; kind="$2"; shift 2
    printf '%s\n' "$refs" | grep -Fxq "$DIR/$file" || { log "跳过未引用规则 $file"; return 0; }
    [ -s "$DIR/$file" ] || { log "ERROR: 缺少旧规则 $file"; return 1; }
    for url in "$@"; do
        log "下载 $file: $url"
        rm -f "$WORK/raw"
        if curl -4 --http1.1 -fsSL --connect-timeout 10 --max-time 90 --retry 1 "$url" -o "$WORK/raw" &&
            { validate "$kind" "$WORK/raw" "$WORK/$file" || { log "$file 内容校验失败"; false; }; }; then
            oldn="$(grep -cE '^(full|domain|keyword):' "$DIR/$file" || true)"
            newn="$(grep -cE '^(full|domain|keyword):' "$WORK/$file" || true)"
            if [ "$((newn*100))" -lt "$((oldn*70))" ]; then
                log "规则减少超过30%，拒绝该下载结果"
                continue
            fi
            if cmp -s "$DIR/$file" "$WORK/$file"; then
                log "$file 无变化"
            else
                CHANGED="$CHANGED $file"
                log "$file 校验通过，待更新 $newn 条"
            fi
            return 0
        fi
        log "该来源下载或校验失败"
    done
    log "ERROR: $file 全部来源失败，保留旧规则"
    return 1
}
AWA=https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Mosdns_v5-No.Unwelcome.txt
YT=https://raw.githubusercontent.com/kboghdady/youTube_ads_4_pi-hole/refs/heads/master/youtubelist.txt
log "===== TGEEK Ads Updater 2.0.2 ====="
health || die "更新前 DNS 基线检查未通过，未修改规则"
prepare_exclusions || die "YouTube 安全排除清单异常，未修改规则"
stage awavenue.txt awa "$AWA" "https://cdn.jsdelivr.net/gh/TG-Twilight/AWAvenue-Ads-Rule@main/Filters/AWAvenue-Ads-Rule-Mosdns_v5-No.Unwelcome.txt" "https://gh-proxy.com/$AWA" || FAILED=1
stage youtubelist.txt youtube "$YT" "https://cdn.jsdelivr.net/gh/kboghdady/youTube_ads_4_pi-hole@master/youtubelist.txt" "https://gh-proxy.com/$YT" || FAILED=1
# Unreferenced filter.txt is intentionally left untouched.
if printf '%s\n' "$refs" | grep -Fxq "$DIR/filter.txt"; then
    die "filter.txt 已被引用，本版不支持其格式，请保留旧版并检查配置"
fi
if [ "$FAILED" = 1 ]; then die "有规则更新失败，本次不替换任何规则"; fi
[ -n "$CHANGED" ] || {
    if printf '%s\n' "$refs" | grep -Fxq "$DIR/youtubelist.txt"; then
        manifest_health || die "视频清单域名解析异常，请检查其他规则库"
    fi
    log "有效规则无变化，不重启"; exit 0;
}
BACK="/etc/mosdns/tgeek-ads-backup/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACK"
for f in $CHANGED; do cp -p "$DIR/$f" "$BACK/$f"; done
ACTIVE=1
for f in $CHANGED; do
    cp -p "$DIR/$f" "$DIR/$f.new"
    cat "$WORK/$f" > "$DIR/$f.new"
    mv -f "$DIR/$f.new" "$DIR/$f"
done
/etc/init.d/mosdns restart || die "重启失败"
sleep 5
health || die "更新后 DNS 健康检测失败"
if printf '%s\n' "$refs" | grep -Fxq "$DIR/youtubelist.txt"; then
    manifest_health || die "视频清单域名解析异常"
fi
ACTIVE=0
log "更新成功；备份 $BACK"
