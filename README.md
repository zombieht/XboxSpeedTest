# XboxSpeedTest
Simple &amp; Fast SpeedTester for Xbox Download CDN

Xbox下载CDN优选

## 介绍

中国的Xbox玩家越来越难混下去了，微软把国内的CDN中非国行游戏下载资源给做了下架，这真是国行的悲剧。很多DNS返回的节点不是Edgecast的污染节点就是Akamai的龟速节点，为了高速下载我们只能不择手段，这个CDN优选工具就是来临时解决这个状况。

Xbox（包括PC版）游戏下载的国际通用域名是

```
assets1.xboxlive.com
assets2.xboxlive.com
dlassets.xboxlive.com
```

中国Xbox游戏下载的域名则是

```
assets1.xboxlive.cn
assets2.xboxlive.cn
dlassets.xboxlive.cn
```

根据我的实践，**他们是不通用的**，没错，不要把他们混用！不要像某DNS一样把.com的域名302到.cn上，这样很多游戏会下载暂停或者锁到100KB/s！冷门游戏和大部分360游戏依然是龟速的。看了一些大佬的帖子，目前最好的方案是根据个人的网络环境在本地重新测速指派CDN。

## 实践

从某个全球多地PING的网站上，我们获取了xbox全球海外服务器的IP（不包括国内，因为国内的CDN镜像是有问题的），利用模拟http下载的方式，返回结果进行排序，最后写入到本地的域名解析上（可以是路由的DNSMASQ，可以是smartdns，如果你只用PC版，直接写入hosts）



工具原料：

1.一台 Windows、macOS、Linux 或路由器系统设备

2.一台能刷写（LEDE，梅林，padavan）等第三方系统的路由器

3.DNSMASQ 或者SMARTDNS

4.curl

我们写了两个简易脚本来快速完成地址筛选测速的结果。

去Release页面下载最新的脚本。
打开```./configs/cdn.list```把XBOX下载服务器的IP列表添加进去。这里我已经预先放好了，如果你找到了更好的列表，可以自行修改。

### macOS / Linux / OpenWrt

在终端下运行：

```bash
chmod +x XboxSpeedTest.sh
./XboxSpeedTest.sh
```

脚本默认使用 4 个并发测速任务，也可以手动指定：

```bash
./XboxSpeedTest.sh --jobs 4
```

如果 curl 不在默认 PATH 中，可以通过 `CURL_BIN` 指定：

```bash
CURL_BIN=/usr/bin/curl ./XboxSpeedTest.sh
```

### Windows PowerShell

在 PowerShell 下运行：

```powershell
.\XboxSpeedTest.ps1
```

脚本默认使用 4 个并发测速任务，也可以手动指定：

```powershell
.\XboxSpeedTest.ps1 -Jobs 4
```

如果系统禁止执行脚本，可以临时使用：

```powershell
powershell -ExecutionPolicy Bypass -File .\XboxSpeedTest.ps1
```

如果 curl.exe 不在默认 PATH 中，可以通过参数指定：

```powershell
.\XboxSpeedTest.ps1 -CurlPath "C:\Windows\System32\curl.exe"
```

运行后等待十分钟左右，优选测速完毕后会提示最佳服务器，并写入结果。

### 更新 CDN 候选列表

项目提供了一个无第三方依赖的 Python 脚本，用于按中国大陆网络视角收集 Xbox 下载 CDN 候选 IP：

```bash
python3 scripts/update_cdn_list.py --target-count 100 --output configs/cdn.list
```

脚本会读取中国大陆公共 DNS 解析器列表，并补充少量 APNIC 中国 IPv4 地址段采样，再通过 Google DNS-over-HTTPS 的 EDNS Client Subnet 参数解析 Xbox 下载域名。`--target-count 100` 表示最多写入 100 个候选 IP，不会为了凑满 100 个而长时间采样；新结果不足时，会用当前 `configs/cdn.list` 中的旧候选补足。

默认情况下，脚本会对收集到的新候选和当前 `configs/cdn.list` 中的旧候选执行一次真实 Xbox HTTP Range 下载验证。只有能通过 `assets1.xboxlive.com`、`assets2.xboxlive.com` 或 `dlassets.xboxlive.com` 返回有效下载数据的 IP，才会优先写入新列表。更新脚本只验证能否实际下载，不计算速度，也不按速度排序；真实快慢仍由正式测速脚本判断。

如果只想保留旧版“仅收集 DNS 结果，不做 HTTP 探测”的行为，可以使用：

```bash
python3 scripts/update_cdn_list.py --target-count 100 --output configs/cdn.list --skip-probe
```

也可以调整验证超时：

```bash
python3 scripts/update_cdn_list.py --probe-timeout 8
```

GitHub Actions 已配置为北京时间每周一 00:00 自动更新 `configs/cdn.list`，也可以在 Actions 页面手动触发。

## 康康结果：
```
[LOG]All CDN Test complete. Have fun!
[LOG]Your Best CDN is 203.69.138.26, 7388KB/s!
```

结果 `hosts_best_output.txt` 对应 hosts，`smartdns_best_output.txt` 对应 SmartDNS，`merlin_dnsmasq_best_output.txt` 和 `openwrt_dnsmasq_best_output.txt` 对应 DNSMasq，把以上结果复制到路由或者 hosts 中，重启 Xbox 试试下载吧。

## 引用：
http://wap.a9vg.com/thread-5330577-1-1.html?t=1543674360 Xbox 下载更新停止完美解决方案
https://bbs.a9vg.com/thread-5478226-1-1.html Xbox One 当前国内CDN状态分析
