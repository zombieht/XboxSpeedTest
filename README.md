# XboxSpeedTest

Xbox 游戏下载 CDN 优选工具。项目通过真实 HTTP Range 下载测速，帮助你在当前网络环境下筛选更适合 Xbox / PC Game Pass 下载的 CDN 节点，并生成 hosts、SmartDNS、DNSMasq 可用的解析配置。

> [!IMPORTANT]
> `xboxlive.com` 和 `xboxlive.cn` 不建议混用。把 `.com` 域名强行指向 `.cn` 节点，可能导致游戏下载暂停、限速或部分游戏无法正常下载。

## 功能特性

- 支持 macOS、Linux、OpenWrt 和 Windows PowerShell。
- 从 `configs/cdn.list` 读取候选 CDN IP，自动去重后测速。
- 使用单线程顺序测速，避免并发下载互相抢占带宽导致速度结果失真。
- 自动输出 hosts、SmartDNS、DNSMasq 配置文件。
- 提供 CDN 候选列表更新脚本，可通过 GitHub Actions 定时或手动更新。
- 更新候选列表时会验证 IP 是否能实际下载 Xbox 内容，避免大量无效节点进入列表。

## 适用域名

国际版 Xbox / PC Game Pass 下载常用域名：

```text
assets1.xboxlive.com
assets2.xboxlive.com
dlassets.xboxlive.com
```

中国区游戏下载域名：

```text
assets1.xboxlive.cn
assets2.xboxlive.cn
dlassets.xboxlive.cn
```

本项目面向 `.com` 域名的 CDN 优选，不会把 `.com` 和 `.cn` 域名互相替换。

## 环境要求

- Windows、macOS、Linux 或 OpenWrt。
- `curl` 或 `curl.exe`。
- 可选：支持 hosts、SmartDNS 或 DNSMasq 配置的路由器。
- 可选：Python 3，用于更新 `configs/cdn.list`。

## 快速开始

先确认 `configs/cdn.list` 中已有 CDN 候选 IP。项目已内置一份候选列表，也可以按后文说明手动更新。

### macOS / Linux / OpenWrt

```bash
chmod +x XboxSpeedTest.sh
./XboxSpeedTest.sh
```

如果 `curl` 不在默认 `PATH` 中，可以通过 `CURL_BIN` 指定：

```bash
CURL_BIN=/usr/bin/curl ./XboxSpeedTest.sh
```

### Windows PowerShell

```powershell
.\XboxSpeedTest.ps1
```

如果系统禁止执行脚本，可以临时使用：

```powershell
powershell -ExecutionPolicy Bypass -File .\XboxSpeedTest.ps1
```

如果 `curl.exe` 不在默认路径中，可以通过参数指定：

```powershell
.\XboxSpeedTest.ps1 -CurlPath "C:\Windows\System32\curl.exe"
```

## 输出文件

测速完成后，脚本会输出最佳 CDN IP，并生成以下配置文件：

| 文件 | 用途 |
| --- | --- |
| `hosts_best_output.txt` | hosts 配置 |
| `smartdns_best_output.txt` | SmartDNS 配置 |
| `merlin_dnsmasq_best_output.txt` | 梅林 DNSMasq 配置 |
| `openwrt_dnsmasq_best_output.txt` | OpenWrt DNSMasq 配置 |

示例输出：

```text
[LOG]All CDN Test complete. Have fun!
[LOG]Your Best CDN is 23.46.229.26, 10971KB/s!
```

把对应配置写入本机 hosts、路由器 SmartDNS 或 DNSMasq 后，重启 DNS 服务或路由器，再重新尝试 Xbox 下载。

## 更新 CDN 候选列表

项目提供了无第三方依赖的 Python 脚本，用于按中国大陆网络视角收集 Xbox 下载 CDN 候选 IP：

```bash
python3 scripts/update_cdn_list.py --target-count 100 --output configs/cdn.list
```

脚本会执行以下流程：

1. 读取中国大陆公共 DNS 解析器列表。
2. 补充少量 APNIC 中国 IPv4 地址段采样。
3. 通过 Google DNS-over-HTTPS 的 EDNS Client Subnet 参数解析 Xbox 下载域名。
4. 合并新候选和当前 `configs/cdn.list` 中的旧候选。
5. 对候选 IP 执行真实 Xbox HTTP Range 下载验证。
6. 只把能实际返回下载数据的 IP 写入新列表。

更新脚本只验证能否实际下载，不计算速度，也不按速度排序；真实快慢仍由正式测速脚本判断。

跳过 HTTP 下载验证，保留旧版“仅收集 DNS 结果”的行为：

```bash
python3 scripts/update_cdn_list.py --target-count 100 --output configs/cdn.list --skip-probe
```

调整验证超时：

```bash
python3 scripts/update_cdn_list.py --probe-timeout 8
```

## GitHub Actions

仓库已配置 GitHub Actions 自动更新 `configs/cdn.list`：

- 定时运行：北京时间每周一 00:00。
- 手动运行：Actions 页面选择 `Update Xbox CDN list`，点击 `Run workflow`。

工作流运行后，如果 `configs/cdn.list` 有变化，会自动提交：

```text
chore: update xbox cdn list
```

## 常见问题

### 为什么很多 CDN 测速是 0KB/s？

候选 IP 可能只是 DNS 曾经返回过的边缘节点，不代表它能服务当前 Xbox 下载 Host 和测试文件。新版更新脚本会先验证 IP 是否能实际下载 Xbox 内容，可以减少无效候选。

### 为什么更新脚本不直接按速度排序？

更新脚本的目标是维护候选池，只做可下载验证。不同网络出口、时间段和运营商下的速度差异很大，最终速度应在你的实际网络环境中通过 `XboxSpeedTest.sh` 或 `XboxSpeedTest.ps1` 测出来。

### 是否可以把 `.com` 域名指向 `.cn` CDN？

不建议。两套域名并不通用，混用可能导致下载暂停、限速或部分游戏异常。

## 项目文件

```text
.
├── XboxSpeedTest.sh              # macOS / Linux / OpenWrt 测速脚本
├── XboxSpeedTest.ps1             # Windows PowerShell 测速脚本
├── XboxSpeedTest-py3.py          # 旧版 Python 测速脚本
├── configs/cdn.list              # CDN 候选 IP 列表
├── scripts/update_cdn_list.py    # CDN 候选列表更新脚本
└── .github/workflows/            # GitHub Actions 配置
```

## 参考资料

- [Xbox 下载更新停止完美解决方案](http://wap.a9vg.com/thread-5330577-1-1.html?t=1543674360)
- [Xbox One 当前国内 CDN 状态分析](https://bbs.a9vg.com/thread-5478226-1-1.html)

## License

本项目基于 [MIT License](LICENSE) 开源。
