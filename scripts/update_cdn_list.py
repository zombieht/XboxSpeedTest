#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""更新 Xbox 下载 CDN 候选 IP 列表。

脚本通过中国大陆公共 DNS 解析器生成 EDNS Client Subnet（ECS）来源，
再调用 Google DNS-over-HTTPS JSON API 查询 Xbox 下载域名，收集公网 IPv4
候选节点。该脚本不依赖第三方库，适合在 GitHub Actions 中定时运行。
"""

import argparse
import concurrent.futures
import ipaddress
import json
import os
import random
import socket
import struct
import tempfile
import urllib.error
import urllib.parse
import urllib.request


PUBLIC_DNS_CN_URL = "https://public-dns.info/nameserver/cn.txt"
APNIC_DELEGATED_URL = "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"
GOOGLE_DOH_URL = "https://dns.google/resolve"

XBOX_DOWNLOAD_DOMAINS = (
    "assets1.xboxlive.com",
    "assets2.xboxlive.com",
    "dlassets.xboxlive.com",
)

# 中国大陆常见公共 DNS / 运营商 DNS。Public-DNS.info 临时不可用时使用这些
# 种子生成 ECS 子网，保证脚本仍能收集一批国内视角的解析结果。
CHINA_ECS_SEEDS = (
    "223.5.5.5",      # AliDNS
    "223.6.6.6",      # AliDNS
    "119.29.29.29",   # DNSPod
    "182.254.116.116",  # DNSPod
    "114.114.114.114",  # 114DNS
    "114.114.115.115",  # 114DNS
    "180.76.76.76",   # Baidu DNS
    "101.226.4.6",    # DNS 派
    "123.125.81.6",   # DNS 派
    "1.12.12.12",     # 腾讯云公共 DNS
    "120.53.53.53",   # 腾讯云公共 DNS
    "202.96.128.86",  # 上海电信
    "202.96.134.133",  # 上海电信
    "202.106.0.20",   # 北京联通
    "202.106.46.151",  # 北京联通
    "202.99.160.68",  # 河北联通
    "218.2.2.2",      # 江苏电信
    "218.4.4.4",      # 江苏电信
    "202.102.152.3",  # 山东电信
    "202.102.134.68",  # 山东联通
    "202.103.24.68",  # 湖北电信
    "202.103.0.68",   # 湖北联通
    "202.96.209.5",   # 广东电信
    "210.21.196.6",   # 广东联通
    "221.5.88.88",    # 广东联通
    "61.139.2.69",    # 四川电信
    "119.6.6.6",      # 四川联通
    "222.172.200.68",  # 云南电信
    "61.128.128.68",  # 重庆电信
    "219.150.32.132",  # 河南电信
    "202.102.224.68",  # 河南联通
    "202.100.64.68",  # 陕西电信
    "221.11.1.67",    # 陕西联通
    "202.98.0.68",    # 辽宁联通
    "202.97.224.69",  # 黑龙江联通
    "202.102.192.68",  # 安徽电信
    "202.101.224.69",  # 江西电信
    "202.101.172.35",  # 浙江电信
    "202.96.104.15",  # 浙江联通
    "202.101.115.55",  # 福建电信
    "202.99.192.66",  # 山西联通
)


def parse_args():
    """解析命令行参数。"""
    parser = argparse.ArgumentParser(
        description="更新 configs/cdn.list 中的 Xbox CDN 候选 IPv4 列表。"
    )
    parser.add_argument(
        "--target-count",
        type=int,
        default=100,
        help="最多写入的唯一 IPv4 数量，默认 100。",
    )
    parser.add_argument(
        "--output",
        default=os.path.join("configs", "cdn.list"),
        help="输出文件路径，默认 configs/cdn.list。",
    )
    parser.add_argument(
        "--resolver-url",
        default=PUBLIC_DNS_CN_URL,
        help="中国公共 DNS 列表 URL。",
    )
    parser.add_argument(
        "--apnic-url",
        default=APNIC_DELEGATED_URL,
        help="APNIC delegated 数据 URL，用于采样中国大陆 ECS 地址段。",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=8.0,
        help="单次 HTTP 请求超时时间，单位秒。",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=24,
        help="并发查询线程数，默认 24。",
    )
    parser.add_argument(
        "--max-resolvers",
        type=int,
        default=80,
        help="最多使用的中国公共 DNS 解析器数量，默认 80。",
    )
    parser.add_argument(
        "--max-apnic-subnets",
        type=int,
        default=80,
        help="最多使用的 APNIC 中国 IPv4 ECS 子网数量，默认 80。",
    )
    parser.add_argument(
        "--dns-timeout",
        type=float,
        default=1.0,
        help="直连公共 DNS 的 UDP 查询超时时间，单位秒，默认 1。",
    )
    return parser.parse_args()


def is_public_ipv4(value):
    """判断字符串是否为公网 IPv4 地址。"""
    try:
        ip_addr = ipaddress.ip_address(value.strip())
    except ValueError:
        return False

    return ip_addr.version == 4 and ip_addr.is_global


def ipv4_sort_key(value):
    """返回 IPv4 数值排序键。"""
    return int(ipaddress.ip_address(value))


def to_ecs_subnet(ip_addr):
    """将 IPv4 地址转换成 /24 ECS 子网。"""
    parts = ip_addr.split(".")
    return "{}.{}.{}.0/24".format(parts[0], parts[1], parts[2])


def int_to_ecs_subnet(ip_value):
    """将 IPv4 整数转换成 /24 ECS 子网。"""
    return "{}.{}.{}.0/24".format(
        (ip_value >> 24) & 255,
        (ip_value >> 16) & 255,
        (ip_value >> 8) & 255,
    )


def deduplicate(items):
    """按输入顺序去重。"""
    result = []
    seen = set()
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def fetch_text(url, timeout):
    """下载文本内容。失败时返回空字符串。"""
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "XboxSpeedTest-CDN-Updater/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8", "ignore")
    except (OSError, urllib.error.URLError):
        return ""


def fetch_china_resolvers(resolver_url, timeout):
    """获取中国大陆公共 DNS 解析器 IPv4 列表。"""
    text = fetch_text(resolver_url, timeout)
    resolvers = []
    for line in text.splitlines():
        ip_addr = line.strip()
        if is_public_ipv4(ip_addr):
            resolvers.append(ip_addr)

    return deduplicate(resolvers)


def build_ecs_subnets(resolvers):
    """根据公共 DNS 和内置种子生成 ECS 子网列表。"""
    seed_ips = list(CHINA_ECS_SEEDS) + list(resolvers)
    ecs_subnets = []
    for ip_addr in seed_ips:
        if is_public_ipv4(ip_addr):
            ecs_subnets.append(to_ecs_subnet(ip_addr))

    return deduplicate(ecs_subnets)


def fetch_apnic_china_ecs_subnets(apnic_url, timeout, max_subnets):
    """从 APNIC 中国 IPv4 分配数据中采样 ECS 子网。"""
    if max_subnets <= 0:
        return []

    text = fetch_text(apnic_url, timeout)
    ecs_subnets = []
    for line in text.splitlines():
        fields = line.split("|")
        if len(fields) < 7:
            continue
        if fields[1] != "CN" or fields[2] != "ipv4":
            continue

        try:
            start_ip = int(ipaddress.IPv4Address(fields[3]))
            address_count = int(fields[4])
        except ValueError:
            continue

        # 小地址段取开头 /24；大地址段额外取中段 /24，提高全国覆盖面。
        sample_offsets = [0]
        if address_count >= 65536:
            sample_offsets.append(address_count // 2)

        for offset in sample_offsets:
            ecs_subnets.append(int_to_ecs_subnet(start_ip + offset))
            if len(ecs_subnets) >= max_subnets:
                return deduplicate(ecs_subnets)

    return deduplicate(ecs_subnets)


def build_resolvers(resolvers, max_resolvers):
    """合并内置种子和远程列表，生成直连查询的 DNS 解析器列表。"""
    seed_ips = list(CHINA_ECS_SEEDS) + list(resolvers)
    public_resolvers = [
        ip_addr for ip_addr in seed_ips if is_public_ipv4(ip_addr)
    ]
    return deduplicate(public_resolvers)[:max_resolvers]


def query_google_doh(domain, ecs_subnet, timeout):
    """查询单个域名在指定 ECS 下的 A 记录。"""
    query = urllib.parse.urlencode(
        {
            "name": domain,
            "type": "A",
            "edns_client_subnet": ecs_subnet,
        }
    )
    request = urllib.request.Request(
        "{}?{}".format(GOOGLE_DOH_URL, query),
        headers={"User-Agent": "XboxSpeedTest-CDN-Updater/1.0"},
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return []

    answers = payload.get("Answer") or []
    cdn_ips = []
    for answer in answers:
        if answer.get("type") == 1 and is_public_ipv4(answer.get("data", "")):
            cdn_ips.append(answer["data"].strip())

    return cdn_ips


def encode_dns_name(domain):
    """将域名编码成 DNS wire format。"""
    encoded = bytearray()
    for label in domain.rstrip(".").split("."):
        label_bytes = label.encode("ascii")
        encoded.append(len(label_bytes))
        encoded.extend(label_bytes)
    encoded.append(0)
    return bytes(encoded)


def read_dns_name(packet, offset):
    """读取 DNS 响应中的域名，支持压缩指针。"""
    labels = []
    jumped = False
    original_offset = offset

    while True:
        if offset >= len(packet):
            raise ValueError("DNS name offset out of range.")

        length = packet[offset]
        if length == 0:
            offset += 1
            break

        # 最高两位为 11 表示压缩指针。
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                raise ValueError("DNS compression pointer out of range.")
            pointer = struct.unpack("!H", packet[offset:offset + 2])[0] & 0x3FFF
            if not jumped:
                original_offset = offset + 2
            offset = pointer
            jumped = True
            continue

        offset += 1
        labels.append(packet[offset:offset + length].decode("ascii", "ignore"))
        offset += length

    return ".".join(labels), original_offset if jumped else offset


def build_dns_query(domain):
    """构造 A 记录 DNS 查询包。"""
    query_id = random.randint(0, 65535)
    header = struct.pack(
        "!HHHHHH",
        query_id,
        0x0100,  # 标准递归查询。
        1,
        0,
        0,
        0,
    )
    question = encode_dns_name(domain) + struct.pack("!HH", 1, 1)
    return query_id, header + question


def query_udp_dns(domain, resolver, timeout):
    """直连公共 DNS 解析器查询 A 记录。"""
    query_id, packet = build_dns_query(domain)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(packet, (resolver, 53))
            response, _ = sock.recvfrom(4096)
    except OSError:
        return []

    try:
        (
            response_id,
            _flags,
            question_count,
            answer_count,
            _authority_count,
            _additional_count,
        ) = struct.unpack("!HHHHHH", response[:12])
        if response_id != query_id:
            return []

        offset = 12
        for _ in range(question_count):
            _, offset = read_dns_name(response, offset)
            offset += 4

        cdn_ips = []
        for _ in range(answer_count):
            _, offset = read_dns_name(response, offset)
            answer_type, answer_class, _ttl, data_len = struct.unpack(
                "!HHIH",
                response[offset:offset + 10],
            )
            offset += 10
            answer_data = response[offset:offset + data_len]
            offset += data_len

            if answer_type == 1 and answer_class == 1 and data_len == 4:
                ip_addr = socket.inet_ntoa(answer_data)
                if is_public_ipv4(ip_addr):
                    cdn_ips.append(ip_addr)
    except (struct.error, ValueError):
        return []

    return cdn_ips


def collect_cdn_ips(ecs_subnets, resolvers, timeout, dns_timeout, workers):
    """并发收集 Xbox 下载域名的 CDN IPv4 候选。"""
    doh_jobs = [
        (domain, ecs_subnet)
        for ecs_subnet in ecs_subnets
        for domain in XBOX_DOWNLOAD_DOMAINS
    ]
    dns_jobs = [
        (domain, resolver)
        for resolver in resolvers
        for domain in XBOX_DOWNLOAD_DOMAINS
    ]
    collected_ips = set()

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(query_google_doh, domain, ecs_subnet, timeout)
            for domain, ecs_subnet in doh_jobs
        ]
        futures.extend(
            executor.submit(query_udp_dns, domain, resolver, dns_timeout)
            for domain, resolver in dns_jobs
        )
        for future in concurrent.futures.as_completed(futures):
            try:
                cdn_ips = future.result()
            except Exception:
                cdn_ips = []
            for ip_addr in cdn_ips:
                collected_ips.add(ip_addr)

    return sorted(collected_ips, key=ipv4_sort_key)


def read_existing_ips(output_path):
    """读取现有 cdn.list，用于新结果不足时补足。"""
    if not os.path.exists(output_path):
        return []

    existing_ips = []
    with open(output_path, "r", encoding="utf-8") as input_file:
        for line in input_file:
            ip_addr = line.strip()
            if is_public_ipv4(ip_addr):
                existing_ips.append(ip_addr)

    return deduplicate(existing_ips)


def build_final_list(new_ips, existing_ips, target_count):
    """合并新旧结果，生成最终输出列表。"""
    merged = deduplicate(list(new_ips) + list(existing_ips))
    merged = sorted(merged, key=ipv4_sort_key)
    return merged[:target_count]


def write_atomic(output_path, cdn_ips):
    """使用临时文件原子替换输出文件。"""
    output_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(output_dir, exist_ok=True)

    fd, temp_path = tempfile.mkstemp(
        prefix=".cdn.list.",
        suffix=".tmp",
        dir=output_dir,
        text=True,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as temp_file:
            for ip_addr in cdn_ips:
                temp_file.write("{}\n".format(ip_addr))
        os.replace(temp_path, output_path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def main():
    """脚本入口。"""
    args = parse_args()
    if args.target_count <= 0:
        raise ValueError("--target-count 必须大于 0。")
    if args.workers <= 0:
        raise ValueError("--workers 必须大于 0。")
    if args.max_resolvers < 0:
        raise ValueError("--max-resolvers 不能小于 0。")
    if args.max_apnic_subnets < 0:
        raise ValueError("--max-apnic-subnets 不能小于 0。")

    fetched_resolvers = fetch_china_resolvers(args.resolver_url, args.timeout)
    resolvers = build_resolvers(fetched_resolvers, args.max_resolvers)
    ecs_subnets = build_ecs_subnets(resolvers)
    apnic_ecs_subnets = fetch_apnic_china_ecs_subnets(
        args.apnic_url,
        args.timeout,
        args.max_apnic_subnets,
    )
    ecs_subnets = deduplicate(ecs_subnets + apnic_ecs_subnets)
    new_ips = collect_cdn_ips(
        ecs_subnets,
        resolvers,
        args.timeout,
        args.dns_timeout,
        args.workers,
    )
    existing_ips = read_existing_ips(args.output)
    final_ips = build_final_list(new_ips, existing_ips, args.target_count)

    write_atomic(args.output, final_ips)

    print(
        "Collected {} new IPs, merged {} existing IPs, wrote {} IPs to {}.".format(
            len(new_ips),
            len(existing_ips),
            len(final_ips),
            args.output,
        )
    )


if __name__ == "__main__":
    main()
