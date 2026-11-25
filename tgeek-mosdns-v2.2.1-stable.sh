#!/bin/sh

# TGEEK MosDNS v2.2.1 integrated DNS Guard

# Upgrade from TGEEK v2.0 OR clean install for compatible sbwml UCI MosDNS v5.

# Requires jsonfilter for structural JSON verification, curl/wget for downloads.

# Optional DNS Guard changes only its own firewall4 include and chain.

set -eu

umask 077



VERSION=2.2.1

INIT=/etc/init.d/mosdns
MARK=TGEEK-ADFIX-V1
BASE=/etc/mosdns

RULE="$BASE/rule/whitelist.txt"

CUSTOM="$BASE/rule/tgeek-force-local-custom.txt"

CFG=/etc/config/mosdns

LIVE=/var/etc/mosdns.json

BIN=/usr/bin/tgeek-mosdns

CRON=/etc/crontabs/root

BACK="$BASE/tgeek-v22-safe-backup"

INITIAL="$BACK/initial"

LATEST="$BACK/latest"

LOCK=/var/lock/tgeek-mosdns-v21.lock

START='# >>> TGEEK-MOSDNS-MANAGED RULES >>>'

END='# <<< TGEEK-MOSDNS-MANAGED RULES <<<'

OLDCRON='# TGEEK-MOSDNS-AUTO-UPDATE'

NEWCRON='# TGEEK-MOSDNS-V21-WEEKLY'

SOURCE=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release

MIRROR=https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release

WORK=''

STAGE=''

ACTIVE=0

COMMITTED=0



say(){ printf '[TGEEK v%s] %s\n' "$VERSION" "$*"; }

fail(){ printf '[TGEEK v%s] ERROR: %s\n' "$VERSION" "$*" >&2; exit 1; }

exists(){ command -v "$1" >/dev/null 2>&1; }

backup_one(){

  name="$1"; dir="$2"

  # absolute path mapped to a flat, unambiguous backup key

  key="$(printf '%s' "$name" | sed 's#/#_#g')"

  if [ -f "$name" ]; then cp -p "$name" "$dir/$key"; else : > "$dir/$key.absent"; fi

}

restore_one(){

  name="$1"; dir="$2"

  key="$(printf '%s' "$name" | sed 's#/#_#g')"

  if [ -f "$dir/$key" ]; then

    mkdir -p "$(dirname "$name")"

    cp -p "$dir/$key" "$name"

  elif [ -f "$dir/$key.absent" ]; then

    rm -f "$name"

  else

    return 1

  fi

}

snapshot(){

  dest="$1"

  [ ! -e "$dest" ] || fail "备份已存在，拒绝覆盖：$dest"

  mkdir -p "$dest"

  backup_one "$INIT" "$dest"
  backup_one "$CFG" "$dest"

  backup_one "$RULE" "$dest"

  backup_one "$CUSTOM" "$dest"

  backup_one "$CRON" "$dest"

  backup_one "$BIN" "$dest"

  backup_one "$BASE/cache.dump" "$dest"

  : > "$dest/complete"

}

restore(){

  dest="$1"

  [ -f "$dest/complete" ] || { say "缺少完整备份：$dest"; return 1; }

  restore_one "$INIT" "$dest" || return 1
  restore_one "$CFG" "$dest" || return 1

  restore_one "$RULE" "$dest" || return 1

  restore_one "$CUSTOM" "$dest" || return 1

  restore_one "$CRON" "$dest" || return 1

  restore_one "$BIN" "$dest" || return 1

  restore_one "$BASE/cache.dump" "$dest" || return 1

  # remove uncommitted UCI delta, then restart with restored original files

  uci revert mosdns >/dev/null 2>&1 || true

  [ -f "$CRON" ] && crontab "$CRON" >/dev/null 2>&1 || true

  /etc/init.d/mosdns restart || return 1

  return 0

}

cleanup(){

  code=$?

  trap - EXIT HUP INT TERM

  set +e

  if [ "$ACTIVE" -eq 1 ] && [ "$COMMITTED" -ne 1 ]; then

    if [ -f "$LATEST" ]; then

      d="$(cat "$LATEST")"

      say "执行失败，自动恢复事务前状态：$d"

      restore "$d"

      if [ $? -ne 0 ]; then

        say "自动回滚没有完成！请用备份目录手工恢复：$d"

      fi

    fi

  fi

  [ -n "$WORK" ] && rm -rf "$WORK"

  [ -n "$STAGE" ] && rm -rf "$STAGE"

  rmdir "$LOCK" >/dev/null 2>&1 || true

  exit "$code"

}

lock(){

  mkdir -p /var/lock
  mkdir "$LOCK" 2>/dev/null || fail "已有更新任务正在运行：$LOCK"

  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

}

json(){ jsonfilter -i "$LIVE" -e "$1" 2>/dev/null; }

# Parse rather than grep serialized JSON: normalized URLs and escaped slashes are handled.

plugin_index(){

  wanted="$1"

  i=0

  tags="$(json '@.plugins[*].tag')" || return 1

  for tag in $tags; do

    if [ "$tag" = "$wanted" ]; then printf '%s' "$i"; return 0; fi

    i=$((i+1))

  done

  return 1

}

check_runtime(){

  [ -f "$CFG" ] && [ -f "$LIVE" ] || fail '找不到 MosDNS UCI/JSON 配置'

  exists jsonfilter || fail '缺少 jsonfilter，请先安装 jsonfilter 软件包'

  exists uci || fail '缺少 uci'

  exists pidof || fail '缺少 pidof'

  [ "$(uci -q get mosdns.config.configfile || true)" = "$LIVE" ] || fail '当前非 sbwml UCI 自动生成模式，停止（不修改 YAML）'

  p="$(pidof mosdns 2>/dev/null | awk '{print $1}')"

  [ -n "$p" ] || fail 'MosDNS 未运行'

  cmd="$(tr '\000' ' ' < "/proc/$p/cmdline")"

  case "$cmd" in *" -c $LIVE "*) : ;; *) fail '正在运行的 MosDNS 未加载预期 JSON';; esac

  tags="$(json '@.plugins[*].tag')" || fail 'JSON 解析失败'

  [ -n "$tags" ] || fail 'JSON 没有有效插件'

  idxwl="$(plugin_index whitelist)" || fail '找不到 whitelist 插件'

  idxlocal="$(plugin_index forward_local)" || fail '找不到 forward_local 插件'

  idxremote="$(plugin_index forward_remote)" || fail '找不到 forward_remote 插件'

  idxmain="$(plugin_index main_sequence)" || fail '找不到 main_sequence 插件'

  idxqwl="$(plugin_index query_is_whitelist_domain)" || fail '找不到 query_is_whitelist_domain 插件'

  f="$(json "@.plugins[$idxwl].args.files[0]")"

  [ "$f" = "$RULE" ] || fail "白名单文件不是预期路径：$f"

  match="$(json "@.plugins[$idxqwl].args[*].matches")"

  printf '%s\n' "$match" | grep -Fq 'qname $whitelist' || fail '白名单 sequence 没有 qname 匹配'

  execs="$(json "@.plugins[$idxqwl].args[*].exec")"

  printf '%s\n' "$execs" | grep -Fq '$forward_local' || fail '白名单没有走 forward_local'

  order="$(json "@.plugins[$idxmain].args[*].exec")"

  printf '%s\n' "$order" | grep -Fq '$query_is_whitelist_domain' || fail '主流程没有调用白名单'

  before="$(printf '%s\n' "$order" | awk '/\$query_is_whitelist_domain/{exit} /\$query_is_no_local_domain/{print "bad";exit}')"

  [ -z "$before" ] || fail '国外域名规则优先于白名单，停止'

  port="$(json '@.plugins[*].args.listen' | awk -F: 'NF>1 {print $NF;exit}')"

  [ -n "$port" ] || port="$(uci -q get mosdns.config.listen_port || true)"

  say "运行 JSON 正常；端口=${port:-未知}；白名单=$RULE；转发链路已识别"

}

check_doh(){

  idx="$(plugin_index forward_local)" || return 1

  ips="$(json "@.plugins[$idx].args.upstreams[*].addr")" || return 1

  [ -n "$ips" ] || return 1

  for addr in $ips; do

    case "$addr" in https://*|h3://*) : ;; *) say "国内明文/非 DoH 上游: $addr"; return 1;; esac

  done

  json "@.plugins[$idx].args.upstreams[*].insecure_skip_verify" | grep -qx 'true' && return 1

  return 0

}

audit(){

  check_runtime

  say "国内业务上游：$(json "@.plugins[$idxlocal].args.upstreams[*].addr" | tr '\n' ' ')"

  say "国外业务上游：$(json "@.plugins[$idxremote].args.upstreams[*].addr" | tr '\n' ' ')"

  if check_doh; then say '国内转发器上游全部为 DoH'; else say '国内转发器仍包含非 DoH（安装时切换）'; fi

  for name in forward_xinfeng_udp forward_stream_media; do

    if i="$(plugin_index "$name")"; then

      addrs="$(json "@.plugins[$i].args.upstreams[*].addr" | tr '\n' ' ')"

      say "$name 上游：$addrs（仅审计，不修改）"

    fi

  done

  if grep -Fq "$START" "$RULE" 2>/dev/null; then say '发现 v2.0 规则管理区块，支持原地升级'; else say '未发现 v2.0 管理区块，走首次安装/原名单增量合并'; fi

  say '提示：Bootstrap 以及终端自带 DNS 不在本补丁的零明文保障范围'

}

fetch(){

  f="$1"

  if exists curl; then

    curl -fsSL --connect-timeout 12 --max-time 180 "$SOURCE/$f" -o "$WORK/$f" && return 0

    curl -fsSL --connect-timeout 12 --max-time 180 "$MIRROR/$f" -o "$WORK/$f" && return 0

  elif exists wget; then

    wget -q -T 180 -O "$WORK/$f" "$SOURCE/$f" && return 0

    wget -q -T 180 -O "$WORK/$f" "$MIRROR/$f" && return 0

  fi

  fail "下载失败：$f；旧配置未改动"

}

prepare(){

  WORK="$(mktemp -d /tmp/tgeek-mosdns-XXXXXX)" || fail '无法创建临时目录'

  fetch china-list.txt

  fetch apple-cn.txt

  fetch google-cn.txt

  for f in china-list.txt apple-cn.txt google-cn.txt; do

    [ -s "$WORK/$f" ] || fail "$f 为空"

    ! grep -Eiq '<html|<\!doctype|404: Not Found|Bad Gateway' "$WORK/$f" || fail "$f 返回了网页"

  done

  awk '

    {gsub(/\r/,"");gsub(/^[ \t]+|[ \t]+$/,"");if($0==""||$0~/^#/)next;

     if($0~/^(domain|full):[A-Za-z0-9._-]+$/)print tolower($0);

     else if($0~/^[A-Za-z0-9._-]+$/)print "domain:"tolower($0);

     else bad++}

    END{if(bad)exit 3}

  ' "$WORK/china-list.txt" "$WORK/apple-cn.txt" "$WORK/google-cn.txt" > "$WORK/github" || fail '规则格式异常'

  [ "$(wc -l < "$WORK/china-list.txt")" -gt 50000 ] || fail 'china-list 内容过少'

  [ "$(wc -l < "$WORK/apple-cn.txt")" -gt 20 ] || fail 'apple-cn 内容过少'

  [ "$(wc -l < "$WORK/google-cn.txt")" -gt 20 ] || fail 'google-cn 内容过少'

  [ "$(wc -l < "$WORK/github")" -gt 50000 ] || fail '规则数量异常'

  if [ -n "${TGEEK_CUSTOM_STAGE:-}" ] && [ -f "$TGEEK_CUSTOM_STAGE" ]; then

    cp "$TGEEK_CUSTOM_STAGE" "$WORK/custom_source"

  elif [ -f "$CUSTOM" ]; then

    cp "$CUSTOM" "$WORK/custom_source"

  else

    printf '# TGEEK custom forced local DNS\ndomain:epsonconnect.com\n' > "$WORK/custom_source"

  fi

  awk '

    {gsub(/\r/,"");gsub(/^[ \t]+|[ \t]+$/,"");if($0==""||$0~/^#/)next;

     if($0~/^(domain|full):[A-Za-z0-9._-]+$/)print tolower($0);

     else if($0~/^[A-Za-z0-9._-]+$/)print "domain:"tolower($0);

     else bad++}

    END{if(bad)exit 3}

  ' "$WORK/custom_source" > "$WORK/custom_rules" || fail '自定义规则有无效行'

  cat "$WORK/github" "$WORK/custom_rules" | LC_ALL=C sort -u > "$WORK/managed"

  # Ensure Epson remains included even if user removed it from custom.

  grep -Fqx 'domain:epsonconnect.com' "$WORK/managed" || {

    printf 'domain:epsonconnect.com\n' >> "$WORK/managed"

    LC_ALL=C sort -u "$WORK/managed" > "$WORK/managed.new"

    mv "$WORK/managed.new" "$WORK/managed"

  }

  say "规则校验完成：$(wc -l < "$WORK/managed" | tr -d ' ') 条"

}

check_markers(){

  [ -f "$RULE" ] || return 0

  a="$(grep -Fxc "$START" "$RULE" || true)"

  b="$(grep -Fxc "$END" "$RULE" || true)"

  if [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then return 0; fi

  [ "$a" -eq 1 ] && [ "$b" -eq 1 ] || fail '原 v2.0 管理区块标记损坏，停止以防误删'

  awk -v s="$START" -v e="$END" '$0==s {a=NR} $0==e {b=NR} END{exit !(a>0 && b>a)}' "$RULE" || fail '规则管理区块次序损坏'

}

compose(){

  check_markers

  if [ -f "$RULE" ]; then

    awk -v s="$START" -v e="$END" '$0==s{skip=1;next}$0==e{skip=0;next}!skip{print}' "$RULE" > "$WORK/base"

  else

    : > "$WORK/base"

  fi

  {

    cat "$WORK/base"

    printf '\n%s\n' "$START"

    printf '# TGEEK v2.2; Loyalsoldier china-list apple-cn google-cn\n'

    cat "$WORK/managed"

    printf '%s\n' "$END"

  } > "$WORK/whitelist.new"

}

generate_patch(){
cat > "$WORK/prepare" <<'PART'
    # TGEEK-ADFIX-V1
    mkdir -p /var/etc || return 1
    awk '
        $0=="# >>> TGEEK-MOSDNS-MANAGED RULES >>>" {skip=1; a++; s=NR; next}
        $0=="# <<< TGEEK-MOSDNS-MANAGED RULES <<<" {skip=0; b++; e=NR; next}
        !skip {print}
        END {if(a!=1 || b!=1 || s>=e) exit 1}
    ' /etc/mosdns/rule/whitelist.txt > /var/etc/tgeek-mosdns-trusted.txt.new || return 1
    printf '\n' >> /var/etc/tgeek-mosdns-trusted.txt.new || return 1
    cat /etc/mosdns/rule/tgeek-force-local-custom.txt >> /var/etc/tgeek-mosdns-trusted.txt.new || return 1
    printf '\ndomain:epsonconnect.com\n' >> /var/etc/tgeek-mosdns-trusted.txt.new || return 1
    mv -f /var/etc/tgeek-mosdns-trusted.txt.new /var/etc/tgeek-mosdns-trusted.txt || return 1
PART
cat > "$WORK/plugin" <<'PART'
    json_add_object
    json_add_string "tag" "tgeek_trusted"
    json_add_string "type" "domain_set"
    json_add_object "args"
    json_add_array "files"
    json_add_string "" "/var/etc/tgeek-mosdns-trusted.txt"
    json_close_array
    json_close_object
    json_close_object
PART
cat > "$WORK/sequence" <<'PART'
    json_add_object
    json_add_string "tag" "query_is_tgeek_trusted"
    json_add_string "type" "sequence"
    json_add_array "args"
    [ "$prefer_ipv4_cn" -eq 1 ] && {
        json_add_object
        json_add_string "exec" "prefer_ipv4"
        json_close_object
    }
    json_add_object
    json_add_string "matches" "qname \$tgeek_trusted"
    json_add_string "exec" "\$forward_local"
    json_close_object
    json_close_array
    json_close_object
PART
cat > "$WORK/forward" <<'PART'
    json_add_string "exec" "\$query_is_whitelist_domain"
    json_close_object
    json_add_object
    json_add_string "exec" "jump has_resp_sequence"
    json_close_object
    json_add_object
PART
awk -v dir="$WORK" '
function emit(n, f,l,r){f=dir "/" n; while((r=getline l < f)>0)print l; close(f); if(r<0)exit 4}
/^generate_config\(\)[[:space:]]*\{/ {print; emit("prepare"); a++; next}
/^[[:space:]]*# plugin: whitelist[[:space:]]*$/ {emit("plugin"); b++}
/^[[:space:]]*# plugin: main_sequence[[:space:]]*$/ {emit("sequence"); c++; main=1}
/^[[:space:]]*# plugin: udp_server/ {main=0}
main && /json_add_string "exec"/ && /query_is_whitelist_domain/ {sub(/query_is_whitelist_domain/,"query_is_tgeek_trusted"); d++}
main && /json_add_string "exec"/ && /query_is_greylist_domain/ {emit("forward"); e++}
/&& generate_config[[:space:]]*$/ {sub(/generate_config[[:space:]]*$/,"{ generate_config || return 1; }"); f++}
{print}
END{if(a!=1||b!=1||c!=1||d!=1||e!=1||f!=1)exit 3}
' "$INIT" > "$WORK/patched" || fail '生成器结构不匹配，未修改系统'
sh -n "$WORK/patched" || fail '生成脚本语法错误'
}

check_order(){
  order="$(json '@.plugins[@.tag="main_sequence"].args[*].exec')" || return 1
  printf '%s\n' "$order" | awk '/^\$query_is_tgeek_trusted$/ {a=NR} /^\$query_is_reject_domain$/ {b=NR} /^\$query_is_whitelist_domain$/ {c=NR} END{exit !(a>0&&b>a&&c>b)}'
}
query(){
  dns_port="$(uci -q get mosdns.config.listen_port)" || return 1
  case "$dns_port" in ''|*[!0-9]*) return 1;; esac
  dns_server=127.0.0.1
  [ "$dns_port" = 53 ] || dns_server="127.0.0.1:$dns_port"
  if exists timeout; then timeout 8 nslookup -type="$1" "$2" "$dns_server" 2>/dev/null
  else nslookup -type="$1" "$2" "$dns_server" 2>/dev/null; fi
}
normal(){ query A "$1" | awk '/^Name:/ {answer=1} answer && /^Address:[[:space:]]+/ {ip=$2; if(ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /^(0\.|127\.|198\.18\.|198\.19\.)/) ok=1} END{exit !ok}'; }
blocked(){ query "$1" "$2" | awk -v ip="$3" '/^Name:/ {answer=1} answer && /^Address:[[:space:]]+/ && $2==ip {ok=1} END{exit !ok}'; }
verify_live(){
  check_runtime
  check_doh || return 1
  check_order || { say '广告执行顺序异常'; return 1; }
  normal baidu.com || { say '正常域名解析失败'; return 1; }
  say 'PASS baidu.com 正常解析及广告优先级'
}
report_ads(){
  ads_failed=0
  for d in ad.doubleclick.net pagead2.googlesyndication.com doubleclick.net googleadservices.com adservice.google.com app-measurement.com ad.toutiao.com ad.mi.com ad.qq.com gdt.qq.com adsmind.gdtimg.com; do
    if blocked A "$d" 0.0.0.0 && blocked AAAA "$d" ::; then say "PASS 双栈拦截 $d"; else say "未确认双栈拦截 $d（检查广告库、可信白名单及响应）"; ads_failed=1; fi
  done
  [ "$ads_failed" = 0 ]
}
preflight(){
  [ "$(id -u)" = 0 ] || fail '需要 root'
  port_check="$(uci -q get mosdns.config.listen_port)" || fail '无法识别 DNS 端口'
  case "$port_check" in ''|*[!0-9]*) fail '无效 DNS 端口';; esac
  [ "$port_check" -gt 0 ] && [ "$port_check" -le 65535 ] || fail '无效 DNS 端口' 
  exists nslookup || fail '缺少 nslookup'
  [ -f "$INIT" ] || fail '缺少启动脚本'
  sh -n "$INIT" || fail '原生启动脚本语法错误'
  [ -z "$(uci changes mosdns)" ] || fail '存在未提交 MosDNS 配置，请先保存或撤销'
  check_runtime
  check_markers
  normal baidu.com || fail '现有 DNS 解析或本机 nslookup 端口兼容性检测失败，未修改系统'
}
stage_patch(){
  if grep -Fq "$MARK" "$INIT"; then
    check_order || fail '已有 ADFIX 标记但运行结构不匹配，拒绝覆盖'
    cp -p "$INIT" "$WORK/patched"
  else
    generate_patch
  fi
}
dry_run(){
  preflight
  WORK="$(mktemp -d /tmp/tgeek-v22.XXXXXX)"
  stage_patch
  say 'PASS 配置结构及生成器语法检查；未下载、未修改持久化配置'
}

set_doh(){

  uci -q delete mosdns.config.local_dns || true

  uci add_list mosdns.config.local_dns='https://dns.alidns.com/dns-query'

  uci add_list mosdns.config.local_dns='https://doh.pub/dns-query'

  uci set mosdns.config.custom_local_dns='1'

  uci set mosdns.config.insecure_skip_verify='0'

  # Remove the active Apple branch that can fallback to 114.x.x.x plaintext DNS.

  uci set mosdns.config.apple_optimization='0'

  uci commit mosdns

}

verify_install(){

  /etc/init.d/mosdns restart || return 1

  sleep 3

  # Strict JSON parser; avoid textual false negative on escaped \/.

  check_runtime || return 1

  check_doh || return 1

  # v2.0 had an Apple fallback over UDP, so reject it if still called by main.

  m="$(plugin_index main_sequence)" || return 1

  json "@.plugins[$m].args[*].exec" | grep -Fq '$query_is_apple_domain' && return 1

  [ "$(uci -q get mosdns.config.apple_optimization || true)" = 0 ] || return 1

  [ -f "$RULE" ] && grep -Fqx "$END" "$RULE" || return 1

  pidof mosdns >/dev/null 2>&1 || return 1
  verify_live || return 1
  while IFS= read -r sample; do
    [ -n "$sample" ] || continue
    blocked A "$sample" 0.0.0.0 && blocked AAAA "$sample" :: || {
      say "原有广告拦截退化：$sample"
      return 1
    }
  done < "$WORK/baseline-ads"
  return 0

}

set_cron(){

  if [ -f "$CRON" ]; then
    awk -v a="$OLDCRON" -v b="$NEWCRON" '$0==a || $0==b {next} /[[:space:]]\/usr\/bin\/tgeek-mosdns update([[:space:]]|$)/ {next} {print}' "$CRON" > "$WORK/cron.base"
  else
    : > "$WORK/cron.base"
  fi

  {

    cat "$WORK/cron.base"

    printf '%s\n' "$NEWCRON"

    printf '17 4 * * 0 /usr/bin/tgeek-mosdns update >/tmp/tgeek-mosdns-update.log 2>&1\n'

  } > "$WORK/cron.new"

  cp "$WORK/cron.new" "$CRON"

  crontab "$CRON" >/dev/null 2>&1

}

write_update(){

  preflight

  [ -d "$BASE/rule" ] || fail "缺少 $BASE/rule 目录"

  check_markers

  prepare

  compose
  stage_patch
  : > "$WORK/baseline-ads"
  for sample in ad.doubleclick.net pagead2.googlesyndication.com; do
    if blocked A "$sample" 0.0.0.0 && blocked AAAA "$sample" ::; then
      printf '%s\n' "$sample" >> "$WORK/baseline-ads"
    fi
  done

  # Compare the managed block, not unrelated user whitelist lines.

  if [ -f "$RULE" ]; then

    awk -v s="$START" -v e="$END" '$0==s{f=1;next}$0==e{exit}f&&$0!~/^#/&&NF{print}' "$RULE" > "$WORK/current"

  else

    : > "$WORK/current"

  fi

  migrate=0

  [ -f "$CRON" ] && grep -Fq "$NEWCRON" "$CRON" || migrate=1

  [ -f "$CRON" ] && grep -Fq "$OLDCRON" "$CRON" && migrate=1 || true

  if [ -f "$BIN" ]; then

    cmp -s "$0" "$BIN" || migrate=1

  else

    migrate=1

  fi

  apple_ok=0

  [ "$(uci -q get mosdns.config.apple_optimization || true)" = '0' ] && apple_ok=1

  if cmp -s "$WORK/current" "$WORK/managed" && cmp -s "$WORK/custom_source" "$CUSTOM" && cmp -s "$WORK/patched" "$INIT" && check_order && check_doh && [ "$migrate" -eq 0 ] && [ "$apple_ok" -eq 1 ]; then

    verify_live || fail '当前 DNS 验证失败'
    say '地址库无变化且已安装 v2.2，无需重启'

    return 0

  fi

  mkdir -p "$BACK"

  stamp="$(date +%Y%m%d-%H%M%S)-$$"

  temp="$BACK/.transaction-$stamp"

  snapshot "$temp"

  if [ ! -f "$INITIAL/complete" ]; then

    cp -a "$temp" "$BACK/.initial-$stamp"

    mv "$BACK/.initial-$stamp" "$INITIAL"

  fi

  printf '%s\n' "$temp" > "$LATEST"

  ACTIVE=1

  # Only now mutate persistent files, after the complete transaction snapshot.

  cp "$WORK/custom_source" "$CUSTOM.tmp"

  mv "$CUSTOM.tmp" "$CUSTOM"

  cp "$WORK/whitelist.new" "$RULE.tmp"

  mv "$RULE.tmp" "$RULE"

  cp "$WORK/patched" "$INIT.tgeek-new"
  chmod 755 "$INIT.tgeek-new"
  mv -f "$INIT.tgeek-new" "$INIT"
  set_doh

  verify_install || fail 'DNS 重启/解析链路验证失败；即将自动回滚'

  # Replace the old v2.0 binary only after DNS checks passed.

  [ "$0" = "$BIN" ] || {

    cp "$0" "$BIN.tmp"

    chmod 755 "$BIN.tmp"

    mv "$BIN.tmp" "$BIN"

  }

  set_cron

  COMMITTED=1

  say 'v2.2 已安装/更新成功；失败回滚快照保留'
  report_ads || say '部分广告样本未确认；请检查本机广告库及可信白名单，未自动加入黑名单'

}

status(){

  say "MosDNS PID: $(pidof mosdns 2>/dev/null || echo stopped)"

  say "UCI configfile: $(uci -q get mosdns.config.configfile || true)"

  say "DNS 端口: $(uci -q get mosdns.config.listen_port || echo unknown)"

  say "API 端口: $(uci -q get mosdns.config.listen_port_api || echo unknown)"

  say "国内上游: $(uci -q get mosdns.config.local_dns || true)"

  say "上一事务: $([ -f "$LATEST" ] && cat "$LATEST" || echo none)"

  say "初始备份: $([ -f "$INITIAL/complete" ] && echo present || echo absent)"

  [ -f "$RULE" ] && grep -Fxc "$START" "$RULE" || true

}

rollback(){

  target="${1:-last}"

  case "$target" in

    initial) d="$INITIAL";;

    last) [ -f "$LATEST" ] || fail '没有最近事务快照'; d="$(cat "$LATEST")";;

    *) fail 'rollback 用法: rollback [last|initial]' ;;

  esac

  [ -f "$d/complete" ] || fail "备份不存在：$d"

  ACTIVE=0

  restore "$d" || fail "恢复失败，请检查 $d"
  sleep 3
  normal baidu.com || fail "文件已恢复，但 DNS 验证未通过，请检查 $d"

  say "已恢复：$d"

}

add_remove(){

  action="$1"; d="${2:-}"

  [ -n "$d" ] || fail '请提供域名'

  case "$d" in *[!A-Za-z0-9._-]*|'') fail '域名格式错误';; esac

  d="$(printf '%s' "$d" | tr 'A-Z' 'a-z')"

  printf '%s\n' "$d" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' || fail '必须提供规范域名'

  check_runtime

  # Stage edit before network fetch, never touch live CUSTOM on failure.

  stage="$(mktemp -d /tmp/tgeek-domain-XXXXXX)"

  STAGE="$stage"

  if [ -f "$CUSTOM" ]; then cp "$CUSTOM" "$stage/source"; else printf 'domain:epsonconnect.com\n' > "$stage/source"; fi

  if [ "$action" = add ]; then

    grep -Fqx "domain:$d" "$stage/source" || printf 'domain:%s\n' "$d" >> "$stage/source"

  else

    awk -v d="$d" '$0!="domain:"d && $0!="full:"d && $0!=d{print}' "$stage/source" > "$stage/new"

    mv "$stage/new" "$stage/source"

  fi

  # Use a staged custom list, and remove it on completion/failure.

  export TGEEK_CUSTOM_STAGE="$stage/source"

  write_update

  rm -rf "$stage"

  STAGE=''

  unset TGEEK_CUSTOM_STAGE

}

# DNS Guard is part of this binary, not a separate service.
GUARD_FILE=/etc/nftables.d/40-tgeek-dns-guard.nft
GUARD_CHAIN=tgeek_dns_guard
GUARD_MARK='# TGEEK DNS Guard managed by tgeek-mosdns'

guard_owned(){
  [ -f "$GUARD_FILE" ] && { grep -Fxq "$GUARD_MARK" "$GUARD_FILE" || grep -Fxq '# TGEEK DNS Guard V1.0' "$GUARD_FILE"; }
}
guard_status(){
  if [ -f "$GUARD_FILE" ]; then say 'DNS Guard 持久配置：存在'; else say 'DNS Guard 持久配置：未启用'; fi
  if nft list chain inet fw4 "$GUARD_CHAIN" 2>/dev/null; then :
  elif nft list table inet tgeek_dns_guard 2>/dev/null; then say '当前为旧临时接管';
  else say 'DNS Guard 运行规则：未启用'; fi
}
guard_change() (
  # A subshell isolates the guard transaction from the original DNS transaction.
  set -eu
  action="$1"
  [ "$(id -u)" = 0 ] || fail '需要 root'
  exists nft && exists fw4 || fail '需要 nftables/firewall4'
  [ -d /etc/nftables.d ] || fail '缺少 firewall4 include 目录'
  [ -z "$(uci changes firewall)" ] || fail '存在未提交的防火墙配置'
  if [ -e "$GUARD_FILE" ]; then guard_owned || fail '接管文件非本程序管理，拒绝覆盖'; fi
  if nft list chain inet fw4 "$GUARD_CHAIN" >/dev/null 2>&1; then
    guard_owned || fail '发现同名运行链但没有可识别配置，拒绝修改'
  fi
  gtmp="$(mktemp -d /tmp/tgeek-guard.XXXXXX)"
  gdone=0
  gchanged=0
  gbin=0
  oldfile=0
  if [ -f "$GUARD_FILE" ]; then cp -p "$GUARD_FILE" "$gtmp/old"; oldfile=1; fi
  guard_cleanup(){
    rc=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$gdone" = 0 ]; then
      if [ "$gchanged" = 1 ]; then
        if [ "$oldfile" = 1 ]; then cp -p "$gtmp/old" "$GUARD_FILE"; else rm -f "$GUARD_FILE"; fi
      fi
      if [ "$gbin" = 1 ]; then cp -p "$gtmp/bin" "$BIN.tmp" && mv -f "$BIN.tmp" "$BIN"; fi
    fi
    rm -rf "$gtmp"
    exit "$rc"
  }
  trap guard_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  : > "$gtmp/batch"
  if [ "$action" = enable ]; then
    verify_live || fail '现有 MosDNS 未通过验证，拒绝接管'
    [ "$(uci -q get mosdns.config.listen_port)" = 53 ] || fail '仅支持 MosDNS 监听 53 的设备'
    report_ads || fail '广告样本未通过，拒绝启用接管'
    for proto in tcp udp; do
      netstat -lnptu 2>/dev/null | awk -v p="$proto" '$1==p && $4 ~ /:53$/ && $NF ~ /\/mosdns$/ {ok=1} END{exit !ok}' || fail "MosDNS 未监听 $proto 53"
    done
    [ "$(uci -q get mosdns.config.local_dns_redirect || true)" != 1 ] || fail '请先关闭 MosDNS 原生 DNS 接管'
    for opt in nikki.proxy.ipv4_dns_hijack nikki.proxy.ipv6_dns_hijack nikki.mixin.tun_dns_hijack; do
      [ "$(uci -q get "$opt" || true)" != 1 ] || fail "检测到冲突：$opt"
    done
    lan_dev="$(ubus call network.interface.lan status | jsonfilter -e '@.l3_device')"
    case "$lan_dev" in ''|*[!A-Za-z0-9_.:-]*) fail '无法识别 LAN 网卡';; esac
    [ -d "/sys/class/net/$lan_dev" ] || fail 'LAN 网卡不存在'
    cat > "$gtmp/new" <<RULES
$GUARD_MARK
# Only routed LAN DNS, no OUTPUT or WAN interception.
chain $GUARD_CHAIN {
    type nat hook prerouting priority -160; policy accept;
    iifname != "$lan_dev" return
    fib daddr type local return
    meta nfproto ipv4 udp dport 53 counter redirect to :53 comment "TGEEK IPv4 UDP"
    meta nfproto ipv4 tcp dport 53 counter redirect to :53 comment "TGEEK IPv4 TCP"
    meta nfproto ipv6 udp dport 53 counter redirect to :53 comment "TGEEK IPv6 UDP"
    meta nfproto ipv6 tcp dport 53 counter redirect to :53 comment "TGEEK IPv6 TCP"
}
RULES
    if [ "$oldfile" = 1 ] && cmp -s "$gtmp/new" "$GUARD_FILE" && nft list chain inet fw4 "$GUARD_CHAIN" >/dev/null 2>&1 && ! nft list table inet tgeek_dns_guard >/dev/null 2>&1 && [ "$0" = "$BIN" ]; then
      say 'DNS Guard 已启用，无需重复加载'; gdone=1; exit 0
    fi
  fi
  # Save the old program for a fast upgrade without fetching/restarting MosDNS.
  if [ "$action" = enable ] && [ "$0" != "$BIN" ]; then
    [ -f "$BIN" ] || fail '请先安装 TGEEK MosDNS 基础程序'
    mkdir -p "$BACK"
    cp -p "$BIN" "$gtmp/bin"
    cp -p "$BIN" "$BACK/guard-before-$(date +%Y%m%d-%H%M%S)-$$.sh"
    cp "$0" "$BIN.tmp"; chmod 755 "$BIN.tmp"
    gbin=1
    mv -f "$BIN.tmp" "$BIN"
  fi
  if nft list chain inet fw4 "$GUARD_CHAIN" >/dev/null 2>&1; then
    printf 'flush chain inet fw4 %s\ndelete chain inet fw4 %s\n' "$GUARD_CHAIN" "$GUARD_CHAIN" >> "$gtmp/batch"
  fi
  if [ "$action" = enable ]; then
    { echo 'table inet fw4 {'; cat "$gtmp/new"; echo '}'; } >> "$gtmp/batch"
  fi
  if nft list table inet tgeek_dns_guard >/dev/null 2>&1; then
    nft list chain inet tgeek_dns_guard dns_prerouting >/dev/null 2>&1 || fail '发现未知的同名临时表'
    echo 'delete table inet tgeek_dns_guard' >> "$gtmp/batch"
  fi
  if [ -s "$gtmp/batch" ]; then nft -c -f "$gtmp/batch" || fail '运行规则语法检查失败'; fi
  gchanged=1
  if [ "$action" = enable ]; then
    cp "$gtmp/new" "$GUARD_FILE.tmp"; chmod 644 "$GUARD_FILE.tmp"; mv -f "$GUARD_FILE.tmp" "$GUARD_FILE"
  else
    rm -f "$GUARD_FILE"
  fi
  fw4 check || fail '完整防火墙检查失败，恢复原文件'
  # Apply one atomic nft transaction; no global firewall reload.
  if [ -s "$gtmp/batch" ]; then nft -f "$gtmp/batch" || fail '接管规则加载失败，恢复原文件'; fi
  gdone=1
  say "DNS Guard $action 成功；未重启 MosDNS/Nikki，未全局重载防火墙"
  guard_status
)
guard_upgrade(){
  # Only the verified v2.2 branch supports this fast migration.
  [ -f "$BIN" ] && grep -Eq '^VERSION=2\.2\.[01]$' "$BIN" || fail '快速升级仅支持已安装 V2.2.0/2.2.1；新装请先 install'
  guard_change enable
}
guard_cli(){
  case "${1:-status}" in
    status|stats) guard_status;;
    enable|disable) guard_change "$1";;
    verify) nft list chain inet fw4 "$GUARD_CHAIN" && verify_live && report_ads && say '本机验证通过；接管仍需 LAN 客户端测试';;
    *) fail 'dns-guard {enable|disable|status|stats|verify}';;
  esac
}

case "${1:-}" in

  dry-run) lock; dry_run;;
  verify) verify_live && report_ads;;
  audit) audit; check_order && say '广告优先级正常' || say '广告优先级未确认';;

  status) status; guard_status;;

  install|upgrade|update)
    lock
    case "${2:-}" in
      '') write_update;;
      --dns-guard)
        if [ "$1" = upgrade ]; then guard_upgrade
        elif [ "$1" = install ]; then write_update; guard_change enable
        else fail 'update 不接受 --dns-guard，请使用 dns-guard enable'; fi;;
      *) fail '未知参数';;
    esac;;
  dns-guard) lock; guard_cli "${2:-status}";;

  add|remove) lock; add_remove "$@";;

  rollback) lock; [ ! -e "$GUARD_FILE" ] || fail "请先执行 dns-guard disable，再回滚基础程序"; rollback "${2:-last}";;

  uninstall) lock; [ ! -e "$GUARD_FILE" ] || fail "请先执行 dns-guard disable，再卸载基础程序"; rollback initial;;

  *) echo 'Usage: sh tgeek-mosdns-v2.2.1-stable.sh {dns-guard enable|disable|status|stats|verify; upgrade --dns-guard; dry-run|verify|audit|install|upgrade|update|status|add DOMAIN|remove DOMAIN|rollback [last|initial]|uninstall}'; exit 2;;

esac
