#!/bin/sh
# TGEEK advertising rules updater 2.0.5
set -eu
umask 077
DIR=/etc/mosdns/rule
LIVE=/var/etc/mosdns.json
EXCLUDE="$DIR/tgeek-youtube-exclude.txt"
[ "${1:-}" != --version ] || { echo "TGEEK Ads Updater 2.0.5"; exit 0; }
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
    update|nikki-enable|nikki-disable|nikki-status) ;;
    *) echo "用法：$0 [install|update|nikki-enable|nikki-disable|nikki-status|--version]"; exit 2 ;;
esac
LOG=/var/log/awa-mosdns-update.log
WORK=
BACK=
CHANGED=
ACTIVE=0
FAILED=0
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
# Nikki integration: owned UCI sections, local provider, explicit opt-in.
NNAME=tgeek-youtube-ads
NFILE=/etc/nikki/run/providers/rule/tgeek-youtube-ads.txt
NCFG=/etc/config/nikki
NRUN=/etc/nikki/run/config.yaml
NBACK=
NACTIVE=0
NCONFIG=0
NAPI=http://127.0.0.1:9090
napi(){
    curl --noproxy '*' -fsS --connect-timeout 3 --max-time 15 \
        -H "Authorization: Bearer $(uci -q get nikki.mixin.api_secret || true)" "$@"
}
ncount(){
    napi --max-time 3 "$NAPI/providers/rules" > "$WORK/nproviders-check" || return 1
    jsonfilter -i "$WORK/nproviders-check" -e '@.providers["tgeek-youtube-ads"].ruleCount' 
}
nrule(){
    napi --max-time 3 "$NAPI/rules" > "$WORK/nrules-check" || return 1
    [ "$(jsonfilter -i "$WORK/nrules-check" -e '@.rules[0].payload')" = "$NNAME" ] &&
    [ "$(jsonfilter -i "$WORK/nrules-check" -e '@.rules[0].proxy')" = REJECT ]
}
# Limit the entire readiness loop, not just the number of iterations.
nwait(){
    want="$1"
    start="$(date +%s)"
    i=0
    while [ "$i" -lt 15 ] && [ "$(($(date +%s)-start))" -lt 60 ]; do
        actual=unavailable
        if pidof mihomo >/dev/null && napi --max-time 3 "$NAPI/version" >/dev/null 2>&1; then
            if [ "$want" = off ]; then
                if napi --max-time 3 "$NAPI/rules" > "$WORK/nrules" && jsonfilter -i "$WORK/nrules" -e '@.rules[*].payload' > "$WORK/npayloads" && [ -s "$WORK/npayloads" ] && ! grep -Fxq "$NNAME" "$WORK/npayloads"; then return 0; fi
            else
                actual="$(ncount 2>/dev/null || true)"
                [ -n "$actual" ] || actual=unavailable
                if [ "$actual" = "$want" ] && nrule; then return 0; fi
            fi
        fi
        i=$((i+1))
        log "Nikki 验收 $i/15：期望=$want，实际=$actual（同时检查规则优先级）"
        sleep 2
    done
    return 1
}
nrollback(){
    [ "$NACTIVE" = 1 ] || return 0
    log "Nikki 联动失败，恢复 $NBACK"
    ok=1
    if [ -f "$NBACK/provider.txt" ]; then
        cp -p "$NBACK/provider.txt" "$NFILE.restore" && mv -f "$NFILE.restore" "$NFILE" || ok=0
    else
        rm -f "$NFILE" || ok=0
    fi
    if [ "$NCONFIG" = 1 ]; then
        uci -q revert nikki || true
        cp -p "$NBACK/nikki" "$NCFG.restore" && mv -f "$NCFG.restore" "$NCFG" || ok=0
        log "正在恢复 Nikki 服务（最多90秒）"
        timeout -s KILL 90 /etc/init.d/nikki restart || ok=0
        sleep 5
        pidof mihomo >/dev/null || ok=0
    else
        napi -X PUT "$NAPI/providers/rules/$NNAME" >/dev/null || ok=0
    fi
    [ "$ok" = 1 ] || log "ERROR: Nikki 回滚未完全验证，请检查 $NBACK"
    NACTIVE=0
}
nsync(){
    action="$1"
    if [ ! -f "$NCFG" ] || [ ! -x /etc/init.d/nikki ]; then
        [ "$action" = auto ] && { log "未安装 Nikki，跳过联动"; return 0; }
        die "未安装 Nikki"
    fi
    if [ "$action" = auto ] && [ "$(uci -q get nikki.tgeek_youtube_rule.enabled || true)" != 1 ]; then
        log "Nikki 联动未启用，跳过"; return 0
    fi
    if [ "$action" = off ] && [ "$(uci -q get nikki.tgeek_youtube_rule.enabled || true)" != 1 ]; then
        log "Nikki 联动已关闭"; return 0
    fi
    [ -z "$(uci changes nikki)" ] || die "Nikki 有未提交配置，请先保存或取消"
    pidof mihomo >/dev/null || die "Nikki 未运行，未修改配置"
    [ "$(uci -q get nikki.config.core_only || echo 0)" = 0 ] || die "不支持 core-only 模式"
    # Only auto-enable a disabled mixin if no unrelated dormant sections exist.
    [ "$(uci -q get nikki.mixin.mixin_file_content || echo 0)" = 0 ] || die "检测到 YAML 混入模式，本版不自动改动该模式"
    for sw in rule rule_provider; do
        if [ "$(uci -q get nikki.mixin.$sw || echo 0)" != 1 ]; then
            if uci show nikki | grep -E "^nikki\.[^.]+=$sw$" | grep -vE '^nikki\.tgeek_youtube_(rule|provider)=' | grep -q .; then
                die "追加 $sw 已关闭且存在其他配置，拒绝自动开启"
            fi
        fi
    done
    command -v yq >/dev/null || die "缺少 Nikki yq"
    command -v timeout >/dev/null || die "缺少 timeout，未修改 Nikki"
    timeout -s KILL 2 true || die "timeout 不兼容，未修改 Nikki"
    log "Nikki 联动：开始检查配置 ($action)"
    [ -s "$NRUN" ] || die "缺少运行配置"
    controller="$(yq -r '.external-controller // ""' "$NRUN")"
    case "$controller" in *:9090) ;; *) die "本版仅支持当前设备的 9090 API" ;; esac
    napi "$NAPI/version" >/dev/null || die "Nikki API 不可用，未修改配置"
    # Refuse collisions with unrelated named sections or providers.
    for pair in tgeek_youtube_rule:rule tgeek_youtube_provider:rule_provider; do
        sec=${pair%:*}; typ=${pair#*:}
        existing="$(uci -q get "nikki.$sec" || true)"
        [ -z "$existing" ] || [ "$existing" = "$typ" ] || die "UCI 名称冲突 $sec"
    done
    if [ -n "$(uci -q get nikki.tgeek_youtube_provider || true)" ]; then
        [ "$(uci -q get nikki.tgeek_youtube_provider.name || true)" = "$NNAME" ] || die "已有同名 UCI 规则集，拒绝覆盖"
    fi
    if [ -n "$(uci -q get nikki.tgeek_youtube_rule || true)" ]; then
        [ "$(uci -q get nikki.tgeek_youtube_rule.matcher || true)" = "$NNAME" ] || die "已有同名 UCI 规则，拒绝覆盖"
    fi
    if [ -z "$(uci -q get nikki.tgeek_youtube_provider || true)" ]; then
        if yq -e '."rule-providers" | has("tgeek-youtube-ads")' "$NRUN" >/dev/null 2>&1; then
            die "运行配置存在非本程序同名规则集"
        fi
    fi
    if [ "$action" != off ]; then
        [ -s "$DIR/youtubelist.txt" ] || die "缺少 YouTube 本地规则"
        prepare_exclusions || die "排除文件异常"
        # Only exact Googlevideo CDN hosts; do not re-import arbitrary domains.
        awk 'FNR==NR {skip[$0]=1; next}
          {sub(/\r$/, ""); if($0 !~ /^full:/) next; h=tolower(substr($0,6));
           if(h ~ /^r[rs]?[0-9]+---sn-[a-z0-9-]+\.googlevideo\.com$/ && !(h in skip)) print "DOMAIN," h}
        ' "$WORK/exclude" "$DIR/youtubelist.txt" > "$WORK/nraw" || die "转换失败"
        LC_ALL=C sort -u "$WORK/nraw" > "$WORK/nprovider"
        expected="$(wc -l < "$WORK/nprovider" | tr -d ' ')"
        [ "$expected" -ge 100 ] || die "Nikki 规则数异常，未替换"
        if [ -s "$NFILE" ]; then
            oldcount="$(wc -l < "$NFILE")"
            [ "$((expected*100))" -ge "$((oldcount*70))" ] || die "Nikki 规则减少超过30%"
        fi
    else
        expected=off
    fi
    # Existing managed provider: refresh only, do not restart on daily updates.
    if [ "$action" != off ] && [ "$(uci -q get nikki.tgeek_youtube_rule.enabled || true)" = 1 ] && nrule; then
        if cmp -s "$WORK/nprovider" "$NFILE" && [ "$(ncount)" = "$expected" ]; then
            log "Nikki YouTube 规则 $expected 条，无变化，不重启"; return 0
        fi
        NCONFIG=0
    else
        if [ "$action" = auto ]; then
            die "Nikki 运行规则缺失或优先级异常；MosDNS 更新已独立完成，请手动 nikki-enable 修复"
        fi
        NCONFIG=1
    fi
    NBACK="/etc/mosdns/tgeek-ads-backup/nikki-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$NBACK" "${NFILE%/*}"
    cp -p "$NCFG" "$NBACK/nikki"
    [ ! -f "$NFILE" ] || cp -p "$NFILE" "$NBACK/provider.txt"
    if [ "$NCONFIG" = 1 ]; then
        yq -o=json -I=0 '.rules | map(select(. != "RULE-SET,tgeek-youtube-ads,REJECT"))' "$NRUN" > "$WORK/oldrules"
        yq -o=json -I=0 '(."rule-providers" // {}) | del(."tgeek-youtube-ads") | sort_keys(..)' "$NRUN" > "$WORK/oldproviders"
    fi
    log "Nikki 联动：准备写入规则，备份 $NBACK"
    NACTIVE=1
    if [ "$action" != off ]; then
        cp "$WORK/nprovider" "$NFILE.new"
        chmod 600 "$NFILE.new"
        mv -f "$NFILE.new" "$NFILE"
    fi
    if [ "$NCONFIG" = 0 ]; then
        log "Nikki 联动：API 刷新规则集"
        napi -X PUT "$NAPI/providers/rules/$NNAME" >/dev/null || die "Nikki 规则刷新失败"
    else
        if [ "$action" = off ]; then
            for sw in rule rule_provider; do
                if [ "$(uci -q get nikki.tgeek_youtube_rule.orig_$sw || echo 1)" = 0 ]; then
                    if ! uci show nikki | grep -E "^nikki\.[^.]+=$sw$" | grep -vE '^nikki\.tgeek_youtube_(rule|provider)=' | grep -q .; then
                        uci set "nikki.mixin.$sw=0"
                    fi
                fi
            done
            uci delete nikki.tgeek_youtube_rule
            uci delete nikki.tgeek_youtube_provider
        else
            orig_rule="$(uci -q get nikki.tgeek_youtube_rule.orig_rule || uci -q get nikki.mixin.rule || echo 0)"
            orig_provider="$(uci -q get nikki.tgeek_youtube_rule.orig_rule_provider || uci -q get nikki.mixin.rule_provider || echo 0)"
            uci set nikki.mixin.rule=1
            uci set nikki.mixin.rule_provider=1
            uci set nikki.tgeek_youtube_provider=rule_provider
            uci set nikki.tgeek_youtube_provider.enabled=1
            uci set nikki.tgeek_youtube_provider.name="$NNAME"
            uci set nikki.tgeek_youtube_provider.type=file
            uci set nikki.tgeek_youtube_provider.file_path="$NFILE"
            uci set nikki.tgeek_youtube_provider.file_format=text
            uci set nikki.tgeek_youtube_provider.behavior=classical
            uci set nikki.tgeek_youtube_rule=rule
            uci set nikki.tgeek_youtube_rule.orig_rule="$orig_rule"
            uci set nikki.tgeek_youtube_rule.orig_rule_provider="$orig_provider"
            uci set nikki.tgeek_youtube_rule.enabled=1
            uci set nikki.tgeek_youtube_rule.type=RULE-SET
            uci set nikki.tgeek_youtube_rule.matcher="$NNAME"
            uci set nikki.tgeek_youtube_rule.node=REJECT
            uci set nikki.tgeek_youtube_rule.no_resolve=0
            uci reorder nikki.tgeek_youtube_rule=0
        fi
        # Test a candidate derived from current runtime without editing runtime config.
        if [ "$action" != off ]; then
            yq '."rule-providers"."tgeek-youtube-ads" = {"type":"file","behavior":"classical","format":"text","path":"./providers/rule/tgeek-youtube-ads.txt"} | .rules = (["RULE-SET,tgeek-youtube-ads,REJECT"] + (.rules | map(select(. != "RULE-SET,tgeek-youtube-ads,REJECT"))))' "$NRUN" > "$WORK/nikki-test.yaml"
            bin="$(readlink /proc/$(pidof mihomo | awk '{print $1}')/exe)"
            [ -x "$bin" ] || die "无法识别 Mihomo 内核"
            log "Nikki 联动：Mihomo 预检（最多60秒）"
            timeout -s KILL 60 "$bin" -d /etc/nikki/run -f "$WORK/nikki-test.yaml" -t > "$NBACK/test.log" 2>&1 || die "Mihomo 配置预检失败，详见 $NBACK/test.log"
            log "Mihomo 预检通过"
        fi
        uci commit nikki
        log "Nikki 联动：重启服务（最多90秒）"
        timeout -s KILL 90 /etc/init.d/nikki restart || die "Nikki 重启失败或超时"
        log "Nikki 重启命令完成，开始 API 验收"
    fi
    log "Nikki 联动：校验规则数及首条规则（期望=$expected）"
    nwait "$expected" || die "Nikki 运行规则验收失败"
    if [ "$NCONFIG" = 1 ]; then
        yq -o=json -I=0 '.rules | map(select(. != "RULE-SET,tgeek-youtube-ads,REJECT"))' "$NRUN" > "$WORK/newrules"
        yq -o=json -I=0 '(."rule-providers" // {}) | del(."tgeek-youtube-ads") | sort_keys(..)' "$NRUN" > "$WORK/newproviders"
        cmp -s "$WORK/oldrules" "$WORK/newrules" || die "原有分流规则发生变化，回滚"
        cmp -s "$WORK/oldproviders" "$WORK/newproviders" || die "原有规则集发生变化，回滚"
    fi
    NACTIVE=0
    log "Nikki 联动成功：$expected；备份 $NBACK"
}

cleanup(){
    rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    nrollback
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
case "${1:-update}" in
    nikki-enable) nsync on; exit 0 ;;
    nikki-disable) nsync off; exit 0 ;;
    nikki-status)
        echo "Nikki 联动启用: $(uci -q get nikki.tgeek_youtube_rule.enabled || echo 0)"
        if [ -f "$NFILE" ]; then wc -l "$NFILE"; fi
        echo "运行规则数: $(ncount 2>/dev/null || echo unavailable)"
        if nrule 2>/dev/null; then echo '运行规则: 已加载'; else echo '运行规则: 未确认'; fi
        exit 0 ;;
esac
[ "$(uci -q get mosdns.config.listen_port)" = 53 ] || die "本版健康检测仅支持 53 端口"
[ "$(uci -q get mosdns.config.configfile)" = "$LIVE" ] || die "不是 UCI 自动生成模式"
refs="$(jsonfilter -i "$LIVE" -e '@.plugins[@.tag="adlist"].args.files[*]')"
AWA=https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Mosdns_v5-No.Unwelcome.txt
YT=https://raw.githubusercontent.com/kboghdady/youTube_ads_4_pi-hole/refs/heads/master/youtubelist.txt
log "===== TGEEK Ads Updater 2.0.5 ====="
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
    log "MosDNS 有效规则无变化，不重启"; nsync auto; exit 0;
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

nsync auto
