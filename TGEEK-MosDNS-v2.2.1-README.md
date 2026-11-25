# TGEEK MosDNS V2.2.1

智生活 高效率 · OpenWrt MosDNS 国内 DNS 分流、广告优先级与双栈 DNS 强制接管优化

> 当前版本：V2.2.1（2026-11-25）。基于 V2.2.0 原地升级，DNS Guard 已集成至 `tgeek-mosdns`，无需另装管理程序。广告更新器 V2.0.1 为可选配套工具。

## 1. 功能与适用范围

- 国内上游使用阿里 DoH `https://dns.alidns.com/dns-query` 和腾讯 DoH `https://doh.pub/dns-query`，开启证书验证；关闭原 Apple 明文回退分支。
- 合并 Loyalsoldier 国内、Apple CN、Google CN 域名规则，保留管理区块以外的手工白名单，保护 Epson Connect。
- 修正广告优先级：DDNS → 可信业务名单 → 广告拦截 → 大规模国内白名单 → 后续分流。Hosts、条件缓存和 Redirect 仍位于前面；广告名单查询绕过普通缓存。
- DNS Guard 可选启用：对 LAN 入站、目的地非本机的 TCP/UDP 53 请求执行 IPv4/IPv6 重定向；自动读取 `network.interface.lan` 的 `l3_device`，无需固定 IPv6 PD 前缀。
- DNS Guard 不接管路由器 OUTPUT、WAN、1053 端口，不强制阻断 DoH/DoT，不修改 Nikki 设置。只覆盖经过所识别 LAN 接口的路由流量，不覆盖同一二层网络内直接交换的 DNS、其他 VLAN 或 VPN 内部流量。
- 基础配置事务备份、失败恢复、状态检查、广告双栈样本验证；接管规则独立启停。

**前提**：已正常运行的 sbwml 系 MosDNS v5，使用 UCI 自动生成 `/var/etc/mosdns.json`，白名单路径 `/etc/mosdns/rule/whitelist.txt`；不是通用 YAML 配置安装器。需要 root、uci、jsonfilter、nslookup、curl 或 wget；DNS Guard 还需要 firewall4、nftables、netstat、ubus，且 MosDNS 必须监听 TCP/UDP 53。建议先备份路由器配置，在非业务高峰操作。

## 2. 已安装 V2.2.0：快速覆盖升级（推荐）

将 `tgeek-mosdns-v2.2.1-stable.sh` 上传到 `/tmp`，SSH 登录 OpenWrt 后执行：

```sh
cd /tmp
sh -n tgeek-mosdns-v2.2.1-stable.sh
/usr/bin/tgeek-mosdns verify
sh tgeek-mosdns-v2.2.1-stable.sh upgrade --dns-guard
```

快速路径仅支持已安装 V2.2.0/2.2.1 的设备，复用现有规则；不会主动重启 MosDNS/Nikki、不全局重载防火墙、不重新下载国内规则。会检查本机 DNS、11 个双栈广告样本、53 端口监听、LAN 网卡和 Nikki/MosDNS 原生接管开关；将持久规则写入 firewall4 并以 nft 原子批次替换已知临时接管表。原程序另存于 `/etc/mosdns/tgeek-v22-safe-backup/guard-before-*.sh`。

如只希望升级基础功能而不启用接管：

```sh
sh /tmp/tgeek-mosdns-v2.2.1-stable.sh upgrade
```

普通升级会执行基础规则下载、备份和必要的 MosDNS 重启，不等同于快速路径。若此前已开启 DNS Guard，普通升级不会自动关闭它。

## 3. 首次安装

确认原版 MosDNS 已正常解析、配置已保存，再执行：

```sh
cd /tmp
sh tgeek-mosdns-v2.2.1-stable.sh dry-run
sh tgeek-mosdns-v2.2.1-stable.sh install
```

`dry-run` 检查配置结构和生成器语法，不下载、不修改持久配置。基础安装成功后按需开启：

```sh
tgeek-mosdns verify
tgeek-mosdns dns-guard enable
```

也可用 `sh tgeek-mosdns-v2.2.1-stable.sh install --dns-guard` 连续执行两阶段。若接管阶段失败，已成功安装的基础程序不一定回滚；建议分步安装便于排查。基础安装会关闭原 Apple 优化、写入国内 DoH 并在需要时重启 MosDNS。

## 4. 日常管理

| 命令 | 用途 |
|---|---|
| `tgeek-mosdns status` | 查看进程、端口、上游、备份和接管状态 |
| `tgeek-mosdns audit` | 审计 DNS 转发链路和优先级 |
| `tgeek-mosdns verify` | 验证正常解析、DoH、优先级及 11 个广告样本 |
| `tgeek-mosdns update` | 更新国内规则；必要时重启 MosDNS |
| `tgeek-mosdns add example.com` | 添加可信直连域名并执行规则更新 |
| `tgeek-mosdns remove example.com` | 移除自定义条目并执行规则更新 |
| `tgeek-mosdns dns-guard enable` | 生成并启用 LAN DNS 接管 |
| `tgeek-mosdns dns-guard disable` | 删除本程序接管配置及运行规则 |
| `tgeek-mosdns dns-guard status` | 查看持久配置和运行规则 |
| `tgeek-mosdns dns-guard stats` | 查看四类 NAT 命中计数 |
| `tgeek-mosdns dns-guard verify` | 检查运行链和本机 DNS；仍需 LAN 端测试 |

自定义名单优先于广告规则，请谨慎添加整站域名。NAT 计数是接管命中而非广告数量，重载可能清零。若 LAN 网卡名称变化，重新运行 `dns-guard enable`。

## 5. 安装后验收

OpenWrt SSH：

```sh
grep '^VERSION=' /usr/bin/tgeek-mosdns
tgeek-mosdns status
tgeek-mosdns dns-guard verify
tgeek-mosdns dns-guard stats
/etc/init.d/nikki status
```

Mac/Linux LAN 终端（不是路由器 SSH）：

```sh
dig @223.5.5.5 ad.qq.com A +short
dig @223.5.5.5 ad.qq.com A +tcp +short
dig -6 @2400:3200::1 ad.qq.com A +short
dig -6 @2400:3200::1 ad.qq.com A +tcp +short
dig -6 @2400:3200::1 ad.qq.com AAAA +short
dig @223.5.5.5 baidu.com +short
dig @223.5.5.5 google.com +short
dig @223.5.5.5 epsonconnect.com +short
```

启用后四类 A 测试预期 `0.0.0.0`，AAAA 预期 `::`；正常域名应返回有效地址。IPv6 测试要求客户端具备 IPv6 连接。检查计数增长，再实际访问代理网站及业务服务。安排维护窗口重载防火墙或重启后，重复验证持久规则。DNS 解析正常不等于代理连接一定正常。

## 6. 定时更新及配套广告更新器

基础程序完整安装/更新时配置每周日 04:17：

```cron
17 4 * * 0 /usr/bin/tgeek-mosdns update >/tmp/tgeek-mosdns-update.log 2>&1
```

快速升级保留既有定时任务；现有开机更新任务不会主动改动。基础程序不负责秋风及 YouTube 文件下载。配套 `update-awa-mosdns-rule-v2.0.1.sh` 支持多源下载、秋风 keyword 格式、旧规则保护、有效规则无变化不重启；仅更新当前 MosDNS 引用的文件。

上传配套脚本至 `/tmp`，执行永久安装（仅执行 `sh 文件 install` 并不会永久安装）：

```sh
(
set -e
SRC=/tmp/update-awa-mosdns-rule-v2.0.1.sh
DST=/usr/bin/update-awa-mosdns-rule.sh
sh -n "$SRC"
if [ -f "$DST" ]; then cp -p "$DST" "$DST.bak-$(date +%Y%m%d-%H%M%S)"; fi
cp "$SRC" "$DST.new"
chmod 755 "$DST.new"
mv -f "$DST.new" "$DST"
)
/usr/bin/update-awa-mosdns-rule.sh
```

使用 LuCI「系统 → 计划任务」添加（已有相同任务不重复添加）：

```cron
0 3 * * * /usr/bin/update-awa-mosdns-rule.sh >>/tmp/awa-mosdns-update.log 2>&1
```

检查 `grep -nF '2.0.1' /usr/bin/update-awa-mosdns-rule.sh` 和 `tail -30 /var/log/awa-mosdns-update.log`。广告库需已通过 MosDNS 配置引用，更新器不会自动添加订阅。

## 7. 关闭、回滚与卸载

若 DNS 或代理异常，首先关闭接管（不会主动重启 MosDNS/Nikki）：

```sh
tgeek-mosdns dns-guard disable
```

基础配置回滚（会重启 MosDNS）：

```sh
tgeek-mosdns rollback last
```

`last` 指最近一次**基础配置事务**，并不等同于快速升级前的程序版本。快速升级若只需回退程序，应先关闭接管，再从 `guard-before-*.sh` 中选择正确的备份，`sh -n` 检查后覆盖 `/usr/bin/tgeek-mosdns`。不要盲目选取备份。

恢复初始配置：

```sh
tgeek-mosdns dns-guard disable
tgeek-mosdns rollback initial
```

`tgeek-mosdns uninstall` 同样恢复初始快照，可能恢复旧程序和旧 cron，而非删除全部文件。备份目录保留。不要直接删除备份；回滚可能恢复快照时的 root crontab，请先备份当前计划任务。

## 8. 文件与故障排查

| 路径 | 说明 |
|---|---|
| `/usr/bin/tgeek-mosdns` | 统一管理程序 |
| `/etc/init.d/mosdns` | 修改后的 JSON 生成器 |
| `/etc/config/mosdns` | UCI 配置 |
| `/var/etc/mosdns.json` | 运行时 JSON，勿直接编辑 |
| `/etc/mosdns/rule/whitelist.txt` | 合并白名单 |
| `/etc/mosdns/rule/tgeek-force-local-custom.txt` | 自定义可信名单 |
| `/etc/nftables.d/40-tgeek-dns-guard.nft` | firewall4 持久接管配置 |
| `/etc/mosdns/tgeek-v22-safe-backup/` | 基础事务及快速升级程序备份 |

- 接管启用失败：确认原生 DNS 重定向、Nikki IPv4/IPv6/TUN DNS hijack 已关闭，防火墙无未提交 UCI 更改；不要同时开启多套接管。
- `verify` 广告样本失败：检查实际广告库引用和可信名单；不要为通过测试盲目追加域名。
- 接管规则消失：检查 `fw4 check` 和配置文件，再执行 `tgeek-mosdns dns-guard enable`。
- YouTube 视频内广告、应用 DoH/DoT、硬编码 IP、同域广告不保证被拦截。不要将 11 个样本通过率解释为全网广告拦截率。

## 9. 验证状态及更新说明

V2.2.0 与临时接管核心规则已在 TIJIWrt 实测：11 个双栈广告域名通过，四种普通 DNS 绕过路径接管成功，百度、Google、Epson 域名正常解析，Nikki 进程保持运行。V2.2.1 整合脚本已做 Shell 语法检查；整合版安装、重启持久化及其他机型兼容性仍需实机验收。未声称完整代理兼容或所有广告拦截成功。

上游规则来源：Loyalsoldier/v2ray-rules-dat、TG-Twilight/AWAvenue-Ads-Rule、kboghdady/youTube_ads_4_pi-hole。遵循各上游许可证。本仓库发布脚本，不捆绑第三方规则库。
