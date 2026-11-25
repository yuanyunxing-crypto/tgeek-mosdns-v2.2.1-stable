# TGEEK MosDNS + Ads Updater 统一安装与维护手册

版本：MosDNS v2.2.2 / Ads Updater v2.0.6 · 2026-11-25

## 新版统一入口（先阅读适用范围）

- 新设备（已有正常运行的 MosDNS）：`sh install.sh`。
- 已有 TGEEK v2.2.x：`sh upgrade.sh`，仅替换主程序和更新器，保留现有 Guard 和 cron；不主动重启服务。
- 两个入口均准备缺失规则。若未引用，安全停止并提示在 LuCI 添加，完成后执行 `/usr/bin/update-awa-mosdns-rule.sh update` 和 `sh verify.sh`。不猜测 UCI 字段。
- `sh verify.sh` 严格报告全部广告样本；DNS Guard 只要求核心样本双栈通过，其他样本告警。
- Nikki 缺 timeout：OpenWrt 24.10 执行 `opkg update && opkg install coreutils-timeout`，再检查 yq 和 timeout。
- 本包为待实机验收版；未发布 GitHub。旧版实机补丁已通过四种客户端响应测试，实际计数与重启仍需验证。

## 更新日志

- MosDNS v2.2.2：DNS Guard 非核心广告样本告警、核心双栈强制验证、未启用时明确提示、程序级升级。
- Ads Updater v2.0.6：缺失或未引用规则明确报错，保留事务更新与回滚；Nikki timeout 依赖提示。
- 新增 install.sh、upgrade.sh、verify.sh 统一入口。

## 1. 适用范围与安装包

- `tgeek-mosdns-v2.2.2-stable.sh`：国内 DoH、可信域名、广告优先级、DNS Guard、每周更新及事务回滚。
- `update-awa-mosdns-rule-v2.0.6.sh`：AWA、YouTube 每日更新、安全排除、可选 Nikki 自动联动。
- `prepare-ads-rules.sh`：首次准备缺失的广告规则；保留现有文件，不修改 UCI 或重启服务。

适用于已经安装并正常运行的 sbwml 系 MosDNS v5（UCI 自动生成 `/var/etc/mosdns.json`），OpenWrt firewall4。不是原版 MosDNS 或 Nikki 的安装器。组合方案要求 MosDNS TCP/UDP 53，Nikki 可选；联动要求正常运行的 Mihomo、API 127.0.0.1:9090、可用的 API 密钥设置、yq、timeout，以及兼容 UCI 混入模式。YAML 混入模式或存在未启用的其他追加配置时会安全停止。首次操作建议在非业务时段，通过 LAN SSH 执行。

## 2. 上传与备份（所有设备）

在仓库 [Releases](https://github.com/yuanyunxing-crypto/tgeek-mosdns-v2.2.1-stable/releases) 中选择对应版本（需维护者先上传发布附件），下载 `TGEEK-MosDNS-2.2.2-Ads-2.0.6.tar.gz`，上传至 `/tmp`，执行：

```sh
cd /tmp

wget -O TGEEK-MosDNS-2.2.2-Ads-2.0.6.tar.gz \
'https://gh-proxy.com/https://github.com/yuanyunxing-crypto/tgeek-mosdns-v2.2.1-stable/releases/download/TGEEK-MosDNS-2.2.2-Ads-2.0.6/TGEEK-MosDNS-2.2.2-Ads-2.0.6.tar.gz' && \
tar -xzf TGEEK-MosDNS-2.2.2-Ads-2.0.6.tar.gz && \
cd TGEEK-MosDNS-2.2.2-Ads-2.0.6 && \
sha256sum -c SHA256SUMS && \
sh install.sh
sh verify.sh

sh -n install.sh
sh -n upgrade.sh
sh -n verify.sh
umask 077
sysupgrade -b /tmp/tgeek-before-install.tar.gz
/etc/init.d/mosdns status
uci -q get mosdns.config.configfile
uci -q get mosdns.config.listen_port
nslookup baidu.com 127.0.0.1
```

将备份下载到电脑妥善保存（可能包含凭据）。预期运行配置为 `/var/etc/mosdns.json`，端口 53，正常域名可解析。任何检查失败均先停止。不要并行执行两个更新器（共享互斥锁）。

## 3. 全新安装（已有正常运行的原版 MosDNS）

```sh
cd /tmp/TGEEK-MosDNS-2.2.2-Ads-2.0.6
sh install.sh
```

统一入口校验文件摘要、执行主程序预检及安装、安装广告更新器、准备缺失规则。基础安装可能重启 MosDNS。若规则尚未引用，入口会以非零状态停止，但此前完成的程序安装不会自动撤销；无需重复安装，按下节继续。

### 3.1 广告规则引用与验收

在 LuCI 的 MosDNS 广告规则配置中启用广告过滤，保留已有正常规则，并引用 `/etc/mosdns/rule/awavenue.txt`、`/etc/mosdns/rule/youtubelist.txt`。保存并应用。不同 LuCI 版本菜单名称可能不同。若已经引用，则无需重复添加。保留其他通用广告库，不要把原始 AdGuard `filter.txt` 加入本更新器的 adlist。

```sh
jsonfilter -i /var/etc/mosdns.json -e '@.plugins[@.tag="adlist"].args.files[*]'
nslookup ad.doubleclick.net 127.0.0.1
nslookup manifest.googlevideo.com 127.0.0.1
/usr/bin/tgeek-mosdns verify
```

确认两条路径均在输出中，广告域名返回 0.0.0.0/::，manifest 域名返回正常 IPv4。v2.0.6 要求两套规则均已引用且非空，否则明确报错并停止；只更新已引用且非空的规则文件，不会自动添加 MosDNS 广告规则配置。`verify` 的其他广告样本若失败，先补齐通用广告库或检查可信域名冲突。

```sh
sh verify.sh --refs
/usr/bin/update-awa-mosdns-rule.sh --version
/usr/bin/update-awa-mosdns-rule.sh update
sh verify.sh
```

更新器安装本身不创建广告定时任务；下载失败保留旧规则，无变化不重启。完整验收可能因非核心广告样本未通过而返回非零，需查看具体输出。

### 3.2 可选 DNS Guard

仅当 MosDNS 独占 53 且原生 DNS 重定向及 Nikki 三项 DNS 劫持关闭时启用。先检查：

```sh
uci -q get mosdns.config.local_dns_redirect
uci -q get nikki.proxy.ipv4_dns_hijack
uci -q get nikki.proxy.ipv6_dns_hijack
uci -q get nikki.mixin.tun_dns_hijack
netstat -lnptu | grep ':53 '
```

任一开关为 1 时，先在对应 LuCI 中关闭原接管并验证 LAN DNS，避免双重接管；未安装 Nikki 时其查询无输出正常。DNS Guard 只接管 LAN 转发的传统 TCP/UDP 53，不保证阻止 DoH/DoT，也不接管路由器自身 OUTPUT 或 WAN。

```sh
/usr/bin/tgeek-mosdns dns-guard enable
/usr/bin/tgeek-mosdns dns-guard status
/usr/bin/tgeek-mosdns dns-guard verify
```

失败时不要强制开启；基础程序可以继续使用。

在 LAN 内的 Mac 或 Linux 客户端执行（IPv6 需可用路由）：

```sh
dig @8.8.8.8 ad.doubleclick.net A +short +time=3 +tries=1
dig @8.8.8.8 ad.doubleclick.net A +tcp +short +time=3 +tries=1
dig @2001:4860:4860::8888 ad.doubleclick.net AAAA +short +time=3 +tries=1
dig @2001:4860:4860::8888 ad.doubleclick.net AAAA +tcp +short +time=3 +tries=1
dig @8.8.8.8 baidu.com A +short +time=3 +tries=1
```

预期依次返回 `0.0.0.0`、`0.0.0.0`、`::`、`::` 及正常 IPv4。回到 OpenWrt 执行：

```sh
/usr/bin/tgeek-mosdns dns-guard stats
nft list chain inet fw4 tgeek_dns_guard | grep 'counter packets'
```

对应计数增加才确认 Guard 实际命中；NAT 计数不是全部 DNS 查询数。旧版实机补丁已通过上述四项响应测试，计数与重启恢复尚待确认。

## 4. 已安装设备覆盖升级

适用于已安装 TGEEK MosDNS v2.2.0、v2.2.1 或 v2.2.2 的设备。先完成第 2 节备份与检查。

```sh
cd /tmp/TGEEK-MosDNS-2.2.2-Ads-2.0.6
sh upgrade.sh
```

该入口使用 `upgrade --program-only`，保留现有配置、DNS Guard 与 cron，不主动重启 MosDNS 或 Nikki。缺失规则会准备；未引用则停止并提示按第 3.1 节操作。升级入口不会自动执行广告更新。

```sh
grep '^VERSION=' /usr/bin/tgeek-mosdns
/usr/bin/update-awa-mosdns-rule.sh --version
sh verify.sh --refs
/usr/bin/update-awa-mosdns-rule.sh update
sh verify.sh
```

旧于 v2.2.0 的设备不适用程序级快速升级，应先核对兼容性及备份，不强制覆盖。

## 5. 可选 Nikki 自动联动（无需手动转换）

先确认网页及正常视频播放正常，Nikki API 和已有代理分流运行正常。首次启用会重启 Nikki，可能短暂中断代理，失败会尝试回滚。

```sh
/etc/init.d/nikki status
command -v yq
command -v timeout
/usr/bin/update-awa-mosdns-rule.sh nikki-enable
/usr/bin/update-awa-mosdns-rule.sh nikki-status
```

程序会自动转换符合模式的精确 Googlevideo CDN 域名，排除 `manifest.googlevideo.com` 及自定义安全排除，生成 `tgeek-youtube-ads` 规则集并加入 REJECT 规则，执行预检及 API 验收。日常更新通过 API 刷新；规则无变化不重启。无需手动转换或编辑运行 YAML。初次启用尚待实机验收，若程序失败请保留完整日志，不连续按 Ctrl+C。

运行规则文件：`/etc/nikki/run/providers/rule/tgeek-youtube-ads.txt`。如果 Nikki 重建运行目录或运行规则优先级异常，更新器可能安全停止；先看状态再执行 `nikki-enable` 修复，不盲目重启。

验证：

```sh
/usr/bin/update-awa-mosdns-rule.sh nikki-status
sed -n '/^rules:/,$p' /etc/nikki/run/config.yaml | head -n 20
wc -l /etc/nikki/run/providers/rule/tgeek-youtube-ads.txt
```

规则数量应与 API 加载数一致，首条为 `RULE-SET,tgeek-youtube-ads,REJECT`；实际观看网页与 APP 测试正常视频及广告情况。DNS 和连接层域名拦截无法保证彻底去除 YouTube 插播广告，CDN 规则可能误拦正常视频。

关闭联动：

```sh
/usr/bin/update-awa-mosdns-rule.sh nikki-disable
```

只关闭本工具新增的 Nikki 联动；原有 Nikki 广告规则和 MosDNS 广告过滤继续生效。关闭 Nikki 联动不代表 MosDNS 中相同 CDN 自动放行。

## 6. 定时任务

MosDNS 基础脚本会配置每周日 04:17 更新；Ads Updater 安装保留旧任务，新设备用下列命令添加每天 03:00（保留其他任务，去除旧的同名更新行）：

```sh
(
  set -e
  f=$(mktemp /tmp/tgeek-cron.XXXXXX)
  trap 'rm -f "$f"' EXIT
  (crontab -l 2>/dev/null || true) | awk '!/^[[:space:]]*[^#].*\/usr\/bin\/update-awa-mosdns-rule\.sh([[:space:]]|$)/' > "$f"
  echo '0 3 * * * /usr/bin/update-awa-mosdns-rule.sh update >>/tmp/awa-mosdns-update.log 2>&1' >> "$f"
  crontab "$f"
)
crontab -l
/etc/init.d/cron enable
/etc/init.d/cron start
```

已存在正确任务的设备不必重复执行。推荐错峰：MosDNS 原生更新每天 02:00（若原有配置如此），广告更新每天 03:00，TGEEK MosDNS 每周日 04:17。原生规则更新任务不是本包自动创建。时间按路由器本地时区执行。

## 7. 日常管理与安全排除

```sh
/usr/bin/tgeek-mosdns status
/usr/bin/tgeek-mosdns verify
/usr/bin/tgeek-mosdns audit
/usr/bin/tgeek-mosdns update
/usr/bin/update-awa-mosdns-rule.sh --version
/usr/bin/update-awa-mosdns-rule.sh update
/usr/bin/update-awa-mosdns-rule.sh nikki-status
/usr/bin/tgeek-mosdns dns-guard stats
```

上面是独立命令，不必每天手动执行。日志：`/tmp/awa-mosdns-update.log`（cron 输出）、`/var/log/awa-mosdns-update.log`（程序日志）、`/tmp/tgeek-mosdns-update.log`（每周更新）。

```sh
tail -n 40 /var/log/awa-mosdns-update.log
wc -l /etc/mosdns/rule/awavenue.txt /etc/mosdns/rule/youtubelist.txt
nslookup ad.doubleclick.net 127.0.0.1
nslookup manifest.googlevideo.com 127.0.0.1
```

误拦 CDN 时将确认的完整域名（每行一个，不用泛域名）加入 `/etc/mosdns/rule/tgeek-youtube-exclude.txt`，再运行广告更新。它仅影响本更新器管理的 YouTube 规则，其他广告库仍可能拦截。默认保护 manifest，无需重复添加。不要屏蔽整个 googlevideo.com。

## 8. 故障处理与回滚

### 已有 TGEEK 更新任务

```sh
ps w | grep -E '[u]pdate-awa-mosdns|[t]geek-mosdns|[p]repare-ads-rules|[m]ihomo.*-t|[n]ikki.*restart'
ls -ld /var/lock/tgeek-mosdns-v21.lock
/etc/init.d/mosdns status
/etc/init.d/nikki status
```

仅确认所有更新/安装/回滚任务已结束且服务与配置恢复后，才可执行 `rmdir /var/lock/tgeek-mosdns-v21.lock`；不要 rm -rf。此前 v2.0.4 中断造成的残留锁亦适用。然后执行广告 update。

### Nikki 验收失败

检查程序输出、`/etc/mosdns/tgeek-ads-backup/nikki-*` 内的 `test.log`、`logread -e nikki`、`nikki-status`。日志中 `configuration ... test is successful` 表示配置预检通过，不代表 API 或实际播放已通过。不要公开 API 密钥、订阅 URL 或完整 Nikki 配置。v2.0.6 使用 `/providers/rules` 查询列表，首次启用仍须实机验证。

若需要回退更新器，先成功执行 `nikki-disable`，再从 `/usr/bin/update-awa-mosdns-rule.sh.bak-*` 选择明确的旧版备份，确认无运行任务后 `cp -p` 恢复并验证版本。该操作只恢复脚本，不自动恢复规则内容。广告规则备份位于 `/etc/mosdns/tgeek-ads-backup/`。

### MosDNS 基础功能回滚

先关闭 DNS Guard（如已启用），再回滚；回滚可能恢复旧的 crontab、白名单和程序，因此之后重新检查广告定时任务。选择以下一种，不要连续执行：

```sh
/usr/bin/tgeek-mosdns dns-guard disable
/usr/bin/tgeek-mosdns rollback last
```

恢复首次安装前状态则使用 `rollback initial` 或 `uninstall`（基础程序可能不再存在）。备份位于 `/etc/mosdns/tgeek-v22-safe-backup/`。

## 9. 验收清单

- [ ] MosDNS v2.2.2、Ads Updater v2.0.6 版本正确。
- [ ] 两套广告规则已引用且非空；普通域名和 manifest 可解析，广告样本返回零地址。
- [ ] DNS Guard 如启用，LAN 双栈测试和计数正常。
- [ ] Nikki 如启用，API 数量与文件一致，规则优先级及正常视频播放通过。
- [ ] 每日 03:00 更新任务仅一条；每周日 04:17 任务正确。
- [ ] 次日实际自动更新日志成功，无残留锁。

本包基于上一版两个脚本修订，包含首次准备规则工具和统一入口；新版整包尚未在实际 OpenWrt 路由器完成安装验收。v2.0.6 的联动尚未获得 TIJIWrt 实机成功日志，不能视为已验收的稳定联动。安全排除及规则数不是视频广告拦截率保证。
