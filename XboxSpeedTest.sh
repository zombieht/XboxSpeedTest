#!/usr/bin/env bash
#
# Xbox CDN SpeedTest 的 Bash 版本。
# 说明：
#   1. 读取 configs/cdn.list 中的 CDN IP 地址。
#   2. 使用 curl 对每个 IP 执行指定 Range 的 HTTP 下载测速。
#   3. 找出下载速度最快的 IP，并生成 hosts、SmartDNS、DNSMasq 配置。

set -euo pipefail

readonly CURL_BIN="${CURL_BIN:-curl}"
readonly CURL_MAX_TIME=8
readonly CURL_RANGE="33543139328-33752035327"
readonly CURL_SPEED_TIME=5
readonly CURL_TEST_URL="5/795514b6-aad9-4c1c-ac2a-60c1492d7f31/0c57204f-f4f0-4bf6-b119-b7afc231994d/0.0.61375.0.6574fcb5-72f2-4c85-98c1-bd1059c79934/Destiny2_0.0.61375.0_neutral__z7wx9v9k22rmg"
readonly CURL_HOST="assets1.xboxlive.com"
readonly CDN_CONF_NAME="configs/cdn.list"
readonly DEFAULT_JOBS=4
XBOX_SPEEDTEST_RESULT_FILE=""

# 去除行内空白字符，兼容 Windows 换行。
trim_line() {
  local line="$1"
  line="${line//$'\r'/}"
  line="${line//$'\n'/}"
  line="${line//[[:space:]]/}"
  printf '%s' "${line}"
}

# 判断数组中是否已存在指定 IP。
contains_ip() {
  local target_ip="$1"
  shift

  local ip_addr
  for ip_addr in "$@"; do
    if [[ "${ip_addr}" == "${target_ip}" ]]; then
      return 0
    fi
  done

  return 1
}

# 根据最佳 IP 生成 hosts 格式输出。
generate_hosts_config() {
  local best_ip="$1"

  {
    printf '%s %s\r\n' "${best_ip}" "assets1.xboxlive.com"
    printf '%s %s\r\n' "${best_ip}" "assets2.xboxlive.com"
    printf '%s %s\r\n' "${best_ip}" "dlassets.xboxlive.com"
  } > hosts_best_output.txt
}

# 根据最佳 IP 生成 SmartDNS 格式输出。
generate_smartdns_config() {
  local best_ip="$1"

  {
    printf 'address /%s/%s\r\n' "assets1.xboxlive.com" "${best_ip}"
    printf 'address /%s/%s\r\n' "assets2.xboxlive.com" "${best_ip}"
    printf 'address /%s/%s\r\n' "dlassets.xboxlive.com" "${best_ip}"
  } > smartdns_best_output.txt
}

# 根据最佳 IP 生成 DNSMasq 格式输出，梅林固件可直接使用。
generate_dnsmasq_merlin_config() {
  local best_ip="$1"

  {
    printf 'address=/%s/%s\r\n' "assets1.xboxlive.com" "${best_ip}"
    printf 'address=/%s/%s\r\n' "assets2.xboxlive.com" "${best_ip}"
    printf 'address=/%s/%s\r\n' "dlassets.xboxlive.com" "${best_ip}"
  } > merlin_dnsmasq_best_output.txt
}

# 根据最佳 IP 生成 DNSMasq 格式输出，OpenWrt 可直接使用。
generate_dnsmasq_openwrt_config() {
  local best_ip="$1"

  {
    printf 'address=/%s/%s\r\n' "assets1.xboxlive.com" "${best_ip}"
    printf 'address=/%s/%s\r\n' "assets2.xboxlive.com" "${best_ip}"
    printf 'address=/%s/%s\r\n' "dlassets.xboxlive.com" "${best_ip}"
  } > openwrt_dnsmasq_best_output.txt
}

show_usage() {
  cat <<'USAGE'
Usage: ./XboxSpeedTest.sh [--jobs N]

Options:
  --jobs N    并发测速数量，默认 4。
  -h, --help  显示帮助。
USAGE
}

main() {
  local -a cdn_ips=()
  local all_count=0
  local jobs="${DEFAULT_JOBS}"
  local best_ip=""
  local best_speed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs)
        if [[ $# -lt 2 ]]; then
          printf '[ERROR] --jobs 需要指定并发数量。\n' >&2
          exit 1
        fi
        jobs="$2"
        shift 2
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        printf '[ERROR] 未知参数：%s\n' "$1" >&2
        show_usage >&2
        exit 1
        ;;
    esac
  done

  if [[ ! "${jobs}" =~ ^[0-9]+$ ]] || [[ "${jobs}" -lt 1 ]]; then
    printf '[ERROR] --jobs 必须是大于 0 的整数。\n' >&2
    exit 1
  fi

  if ! command -v "${CURL_BIN}" >/dev/null 2>&1; then
    printf '[ERROR] 未找到 curl，请先安装 curl，或通过 CURL_BIN 指定 curl 路径。\n' >&2
    exit 1
  fi

  if [[ ! -f "${CDN_CONF_NAME}" ]]; then
    printf '[ERROR] 未找到配置文件：%s\n' "${CDN_CONF_NAME}" >&2
    exit 1
  fi

  printf '***************  Xbox CDN SpeedTest *****************\n'
  printf '** Finding your best CDN for Xbox Game Downloads ****\n'

  # 逐行读取 CDN 列表，去重后保留原始顺序，避免重复 IP 浪费测速时间。
  # 这里不使用 Bash 4 的关联数组，保证 macOS 自带 Bash 3.2 也可以运行。
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local ip_addr
    ip_addr="$(trim_line "${raw_line}")"
    if [[ "${ip_addr}" == *.* ]]; then
      if (( ${#cdn_ips[@]} == 0 )) || ! contains_ip "${ip_addr}" "${cdn_ips[@]}"; then
        cdn_ips+=("${ip_addr}")
      fi
    fi
  done < "${CDN_CONF_NAME}"

  all_count="${#cdn_ips[@]}"
  if [[ "${all_count}" -eq 0 ]]; then
    printf '[LOG]All CDN Failed, Bye Bye!\n'
    exit 0
  fi

  XBOX_SPEEDTEST_RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/xbox-speedtest.XXXXXX")"
  trap 'rm -f "${XBOX_SPEEDTEST_RESULT_FILE}"' EXIT
  export CURL_BIN CURL_MAX_TIME CURL_RANGE CURL_SPEED_TIME CURL_TEST_URL CURL_HOST

  # 使用 xargs 按 --jobs 控制并发测速。每个任务输出 TSV，主流程按序号排序后展示，
  # 避免并发输出交错影响阅读。
  for ip_index in "${!cdn_ips[@]}"; do
    printf '%s\t%s\t%s\n' "$((ip_index + 1))" "${all_count}" "${cdn_ips[${ip_index}]}"
  done | xargs -n 3 -P "${jobs}" bash -c '
    index="$1"
    all_count="$2"
    ip_addr="$3"
    speed_bytes="0"
    speed_kb=0
    speed_bytes="$(
      "${CURL_BIN}" \
        -s \
        -o /dev/null \
        -m "${CURL_MAX_TIME}" \
        -r "${CURL_RANGE}" \
        -y "${CURL_SPEED_TIME}" \
        --url "http://${ip_addr}/${CURL_TEST_URL}" \
        -H "Host: ${CURL_HOST}" \
        -w "%{speed_download}" 2>/dev/null
    )" || true
    if [[ "${speed_bytes}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      speed_kb="$(awk -v speed="${speed_bytes}" "BEGIN { printf \"%d\", speed / 1024 }")"
    fi
    printf "[TEST %d/%d] [Address: %s] ....... %dKB/s \n" \
      "${index}" "${all_count}" "${ip_addr}" "${speed_kb}" >&2
    printf "%s\t%s\t%s\t%s\n" "${index}" "${all_count}" "${ip_addr}" "${speed_kb}"
  ' _ > "${XBOX_SPEEDTEST_RESULT_FILE}"

  while IFS=$'\t' read -r cur_index result_all_count ip_addr speed_kb; do
    if (( speed_kb > best_speed )); then
      best_speed="${speed_kb}"
      best_ip="${ip_addr}"
    fi
  done < <(sort -n -k1,1 "${XBOX_SPEEDTEST_RESULT_FILE}")

  printf '[LOG]All CDN Test complete. Have fun!\n'
  if [[ -n "${best_ip}" && "${best_speed}" -gt 0 ]]; then
    printf '[LOG]Your Best CDN is %s, %dKB/s!\n' "${best_ip}" "${best_speed}"
    generate_hosts_config "${best_ip}"
    generate_smartdns_config "${best_ip}"
    generate_dnsmasq_merlin_config "${best_ip}"
    generate_dnsmasq_openwrt_config "${best_ip}"
  else
    printf '[LOG]All CDN Failed, Bye Bye!\n'
  fi
}

main "$@"
