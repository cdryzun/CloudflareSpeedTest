#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
# --------------------------------------------------------------
#	项目: CloudflareSpeedTest 多 IP 自动更新域名解析记录
#	版本: 1.0.3
#	作者: cdryzun
#	项目: https://github.com/cdryzun/CloudflareSpeedTest
# --------------------------------------------------------------
# 功能: 自动获取最快的 N 个 IP (默认 10 个)，并通过 Cloudflare API
#      将这些 IP 全部注册到指定域名（DNS 负载均衡）
# 用途: DNS 负载均衡、高可用性、流量分散
# --------------------------------------------------------------

# 默认配置文件路径
CONFIG_FILE="cfst_ddns_multi.conf"

# 默认 CFST 版本
DEFAULT_CFST_VERSION="v2.3.4"

# 锁文件路径
LOCKFILE="/tmp/cfst_ddns_multi.lock"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
	cat << EOF
CloudflareSpeedTest 多 IP DNS 自动更新脚本 v1.0.3

用法: $0 [选项]

选项:
  -c <文件>    指定配置文件路径（默认: cfst_ddns_multi.conf，可选）
  -h           显示此帮助信息

配置方式（优先级从高到低）:
  1. 环境变量（最高优先级）
  2. 配置文件
  3. 默认值

环境变量列表:
  必填:
    KEY          - Cloudflare API Token
    NAME         - 域名（如 cdn.example.com）

  可选:
    FOLDER       - CFST 目录（留空则自动检测/下载）
    CFST_VERSION - CFST 版本（默认: ${DEFAULT_CFST_VERSION}）
    ZONE_ID      - Zone ID（留空则自动获取）
    EMAIL        - Cloudflare 邮箱（使用旧 API Key 时需要）
    TYPE         - DNS 记录类型（默认: A）
    TTL          - TTL 值（默认: 1）
    PROXIED      - CDN 代理（默认: false）
    IP_COUNT     - IP 数量（默认: 10）
    CFST_PARAMS  - CFST 运行参数

使用示例:

  1. 使用配置文件:
     $0 -c my_domain.conf

  2. 仅使用环境变量（无需配置文件）:
     export KEY="your_api_token"
     export NAME="szddns.coderyzun.cyou"
     $0

  3. 环境变量 + 配置文件（环境变量优先）:
     export NAME="override.example.com"
     $0 -c my_domain.conf

  4. 一行命令:
     KEY=xxx NAME=cdn.example.com TYPE=A TTL=60 PROXIED=false $0

配置文件示例:
  复制模板: cp cfst_ddns_multi.conf.example cfst_ddns_multi.conf
  编辑配置: nano cfst_ddns_multi.conf

更多信息: https://github.com/XIU2/CloudflareSpeedTest
EOF
	exit 0
}

# 解析命令行参数
parse_arguments() {
	while getopts "c:h" opt; do
		case ${opt} in
			c)
				CONFIG_FILE="${OPTARG}"
				;;
			h)
				show_help
				;;
			\?)
				echo "无效选项: -${OPTARG}" >&2
				echo "使用 -h 查看帮助信息"
				exit 1
				;;
			:)
				echo "选项 -${OPTARG} 需要参数" >&2
				exit 1
				;;
		esac
	done
}

# 日志函数
log_info() {
	echo -e "${GREEN}[信息]${NC} $*"
}

log_warn() {
	echo -e "${YELLOW}[警告]${NC} $*"
}

log_error() {
	echo -e "${RED}[错误]${NC} $*"
}

log_success() {
	echo -e "${GREEN}[成功]${NC} $*"
}

# 锁文件管理
acquire_lock() {
	if [[ -e "${LOCKFILE}" ]]; then
		local pid=$(cat "${LOCKFILE}")
		if kill -0 "${pid}" 2>/dev/null; then
			log_error "脚本已在运行中 (PID: ${pid})"
			log_info "如果确认没有其他实例在运行，请删除锁文件: ${LOCKFILE}"
			exit 1
		else
			log_warn "发现旧的锁文件，可能是之前异常退出，正在清理..."
			rm -f "${LOCKFILE}"
		fi
	fi
	echo $$ > "${LOCKFILE}"
}

release_lock() {
	rm -f "${LOCKFILE}"
}

# 设置退出时自动释放锁
trap release_lock EXIT

# 检查依赖
check_dependencies() {
	if ! command -v jq &> /dev/null; then
		log_error "需要安装 jq 工具来解析 JSON"
		log_info "安装方法: apt-get install jq 或 yum install jq"
		exit 1
	fi

	if ! command -v curl &> /dev/null; then
		log_error "需要安装 curl 工具"
		exit 1
	fi

	if ! command -v tar &> /dev/null; then
		log_error "需要安装 tar 工具"
		exit 1
	fi
}

# 检测系统架构
detect_arch() {
	local arch=$(uname -m)
	case ${arch} in
		x86_64|amd64)
			echo "amd64"
			;;
		aarch64|arm64)
			echo "arm64"
			;;
		armv7l|armv7)
			echo "armv7"
			;;
		i386|i686)
			echo "386"
			;;
		*)
			log_error "不支持的架构: ${arch}"
			exit 1
			;;
	esac
}

# 自动检测 CFST 位置
detect_cfst() {
	log_info "正在自动检测 CFST 位置..."

	# 搜索路径列表
	local search_paths=(
		"./cfst"                          # 当前目录
		"../cfst"                         # 上级目录
		"../../cfst"                      # 上上级目录
		"/tmp/cfst"                       # /tmp 目录
		"/usr/local/bin/cfst"             # 系统目录
		"/opt/cfst/cfst"                  # opt 目录
		"$HOME/cfst"                      # 用户目录
		"${PWD}/cfst"                     # 完整路径当前目录
	)

	for path in "${search_paths[@]}"; do
		if [[ -x "${path}" ]]; then
			# 找到可执行的 cfst
			CFST_PATH=$(dirname "$(readlink -f "${path}")")
			log_success "找到 CFST: ${path}"
			return 0
		fi
	done

	log_warn "未找到 CFST 可执行文件"
	return 1
}

# 下载并安装 CFST
download_cfst() {
	local version="${1:-${DEFAULT_CFST_VERSION}}"
	local arch=$(detect_arch)
	local os="linux"

	log_info "准备下载 CFST ${version} (${os}_${arch})..."

	# 下载到 /tmp 目录
	local download_dir="/tmp/cfst_${version}"
	local tar_file="cfst_${os}_${arch}.tar.gz"
	local download_url="https://github.com/XIU2/CloudflareSpeedTest/releases/download/${version}/${tar_file}"

	# 创建下载目录
	mkdir -p "${download_dir}"
	cd "${download_dir}" || { log_error "无法进入目录: ${download_dir}"; exit 1; }

	# 如果已经存在，先清理
	[[ -f "${tar_file}" ]] && rm -f "${tar_file}"

	# 下载
	log_info "下载地址: ${download_url}"
	if ! wget -q --show-progress "${download_url}" 2>&1; then
		log_error "下载失败，请检查网络连接或版本号是否正确"
		log_info "可用版本列表: https://github.com/XIU2/CloudflareSpeedTest/releases"
		exit 1
	fi

	# 解压
	log_info "正在解压..."
	if ! tar xf "${tar_file}"; then
		log_error "解压失败"
		exit 1
	fi

	# 验证
	if [[ ! -x "./cfst" ]]; then
		log_error "解压后未找到 cfst 可执行文件"
		exit 1
	fi

	# 设置执行权限
	chmod +x ./cfst

	CFST_PATH="${download_dir}"
	log_success "CFST ${version} 已下载并安装到: ${CFST_PATH}"
}

# 确保 CFST 可用
ensure_cfst() {
	local cfst_version="${1:-${DEFAULT_CFST_VERSION}}"

	# 如果 FOLDER 已配置，直接使用
	if [[ -n "${FOLDER}" ]]; then
		if [[ -x "${FOLDER}/cfst" ]]; then
			CFST_PATH="${FOLDER}"
			log_info "使用配置的 CFST 路径: ${CFST_PATH}"
			return 0
		else
			log_error "配置的 FOLDER 中未找到 cfst 可执行文件: ${FOLDER}/cfst"
			exit 1
		fi
	fi

	# 尝试自动检测
	if detect_cfst; then
		return 0
	fi

	# 检测不到，询问是否自动下载
	log_warn "未找到 CFST，将自动下载安装"
	log_info "版本: ${cfst_version}"

	# 自动下载
	download_cfst "${cfst_version}"
}

# 读取和验证配置
_READ_CONFIG() {
	# 辅助函数：从配置文件读取配置项
	get_config_from_file() {
		local key="$1"
		if [[ -n "${CONFIG}" ]]; then
			echo "${CONFIG}" | grep "^${key}=" | awk -F '=' '{print $NF}' | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
		fi
	}

	# 辅助函数：获取配置值（优先级：环境变量 > 配置文件 > 默认值）
	get_config() {
		local key="$1"
		local default="$2"
		local env_var="${!key}"  # 间接引用环境变量
		local file_value=$(get_config_from_file "${key}")

		# 优先使用环境变量，其次配置文件，最后默认值
		if [[ -n "${env_var}" ]]; then
			echo "${env_var}"
		elif [[ -n "${file_value}" ]]; then
			echo "${file_value}"
		else
			echo "${default}"
		fi
	}

	# 读取配置文件（如果存在）
	if [[ -e "${CONFIG_FILE}" ]]; then
		log_info "读取配置文件: ${CONFIG_FILE}"
		CONFIG=$(cat "${CONFIG_FILE}")
	else
		log_warn "配置文件不存在: ${CONFIG_FILE}，将仅使用环境变量"
		CONFIG=""
	fi

	# 读取配置（环境变量优先）
	FOLDER=$(get_config 'FOLDER' '')
	CFST_VERSION=$(get_config 'CFST_VERSION' "${DEFAULT_CFST_VERSION}")
	ZONE_ID=$(get_config 'ZONE_ID' '')
	EMAIL=$(get_config 'EMAIL' '')
	IP_COUNT=$(get_config 'IP_COUNT' '10')
	CFST_PARAMS=$(get_config 'CFST_PARAMS' '')

	# 读取必填配置
	KEY=$(get_config 'KEY' '')
	[[ -z "${KEY}" ]] && log_error "缺少配置项 [KEY]，请通过配置文件或环境变量设置" && exit 1

	NAME=$(get_config 'NAME' '')
	[[ -z "${NAME}" ]] && log_error "缺少配置项 [NAME]，请通过配置文件或环境变量设置" && exit 1

	TYPE=$(get_config 'TYPE' 'A')
	[[ "${TYPE}" != "A" && "${TYPE}" != "AAAA" ]] && log_error "TYPE 必须为 A 或 AAAA，当前值: [${TYPE}]" && exit 1

	TTL=$(get_config 'TTL' '1')
	PROXIED=$(get_config 'PROXIED' 'false')

	# 验证 IP_COUNT 范围
	if [[ ${IP_COUNT} -lt 1 || ${IP_COUNT} -gt 100 ]]; then
		log_error "IP_COUNT 必须在 1-100 之间，当前值: ${IP_COUNT}"
		exit 1
	fi

	# 确定认证方式
	if [[ -z "${EMAIL}" ]]; then
		log_info "使用 API 令牌认证方式"
		AUTH_MODE="token"
	else
		log_info "使用 API 密钥认证方式 (${EMAIL})"
		AUTH_MODE="key"
	fi

	log_success "配置读取完成"
	echo ""
	log_info "=== 当前配置 ==="
	log_info "域名: ${NAME}"
	log_info "记录类型: ${TYPE}"
	log_info "TTL: ${TTL}"
	log_info "CDN 代理: ${PROXIED}"
	log_info "IP 数量: ${IP_COUNT}"
	[[ -n "${ZONE_ID}" ]] && log_info "Zone ID: ${ZONE_ID}"
	[[ -n "${FOLDER}" ]] && log_info "CFST 目录: ${FOLDER}"
	[[ -n "${CFST_VERSION}" ]] && log_info "CFST 版本: ${CFST_VERSION}"
	[[ -n "${CFST_PARAMS}" ]] && log_info "CFST 参数: ${CFST_PARAMS}"
	echo ""
}

# IPv4 格式验证
is_valid_ipv4() {
	local ip="$1"
	if [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		local IFS='.'
		local -a octets=($ip)
		for octet in "${octets[@]}"; do
			[[ ${octet} -gt 255 ]] && return 1
		done
		return 0
	fi
	return 1
}

# IPv6 格式验证（简化版）
is_valid_ipv6() {
	local ip="$1"
	[[ ${ip} =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

# 运行 CFST 并提取 IP
_RUN_CFST() {
	log_info "开始运行 CFST 测速..."

	# 检查 CFST 可执行文件
	local cfst_bin="${CFST_PATH}/cfst"
	if [[ ! -x "${cfst_bin}" ]]; then
		log_error "CFST 可执行文件不存在或无执行权限: ${cfst_bin}"
		exit 1
	fi

	# 运行 CFST
	"${cfst_bin}" ${CFST_PARAMS} -o "result_ddns_multi.csv"

	# 检查结果文件
	if [[ ! -e "result_ddns_multi.csv" ]]; then
		log_error "CFST 测速失败，未生成结果文件"
		exit 1
	fi

	# 检查文件是否为空
	local line_count=$(wc -l < "result_ddns_multi.csv")
	if [[ ${line_count} -lt 2 ]]; then
		log_error "CFST 测速结果为空"
		exit 1
	fi

	log_success "CFST 测速完成，共找到 $((line_count - 1)) 个 IP"
}

# 提取和验证 IP
_EXTRACT_IPS() {
	log_info "提取前 ${IP_COUNT} 个最快 IP..."

	# 验证 CSV 格式
	local header=$(head -n1 "result_ddns_multi.csv")
	if [[ ! "${header}" =~ ^IP ]]; then
		log_error "CSV 格式不符合预期"
		log_error "实际标题: ${header}"
		log_error "预期标题: IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码"
		exit 1
	fi

	# 提取 IP 到数组
	IP_LIST=()
	declare -A seen
	local count=0

	while IFS=',' read -r ip rest; do
		# 跳过空行
		[[ -z "${ip}" ]] && continue

		# 去除可能的空格
		ip=$(echo "${ip}" | tr -d ' ')

		# 验证 IP 格式
		local valid=0
		if [[ "${TYPE}" == "A" ]] && is_valid_ipv4 "${ip}"; then
			valid=1
		elif [[ "${TYPE}" == "AAAA" ]] && is_valid_ipv6 "${ip}"; then
			valid=1
		fi

		if [[ ${valid} -eq 1 ]]; then
			# 去重
			if [[ -z "${seen[$ip]}" ]]; then
				IP_LIST+=("${ip}")
				seen[$ip]=1
				((count++))
				[[ ${count} -ge ${IP_COUNT} ]] && break
			fi
		else
			log_warn "跳过无效 IP: ${ip}"
		fi
	done < <(tail -n +2 "result_ddns_multi.csv")

	# 检查提取到的 IP 数量
	if [[ ${#IP_LIST[@]} -eq 0 ]]; then
		log_error "未能提取到有效的 IP 地址"
		exit 1
	fi

	if [[ ${#IP_LIST[@]} -lt ${IP_COUNT} ]]; then
		log_warn "CFST 只返回 ${#IP_LIST[@]} 个 IP，少于请求的 ${IP_COUNT} 个"
		log_info "将使用所有可用的 ${#IP_LIST[@]} 个 IP"
	else
		log_success "成功提取 ${#IP_LIST[@]} 个 IP"
	fi

	# 显示提取到的 IP
	log_info "提取到的 IP 列表:"
	for i in "${!IP_LIST[@]}"; do
		echo "  $((i+1)). ${IP_LIST[$i]}"
	done
}

# API 响应验证
validate_api_response() {
	local response="$1"
	local operation="$2"

	# 检查是否为有效 JSON
	if ! echo "${response}" | jq empty 2>/dev/null; then
		log_error "${operation} - API 返回无效 JSON"
		return 1
	fi

	# 检查 success 字段
	local success=$(echo "${response}" | jq -r '.success')
	if [[ "${success}" != "true" ]]; then
		local errors=$(echo "${response}" | jq -r '.errors[]?.message' 2>/dev/null | tr '\n' '; ')
		log_error "${operation} - ${errors}"
		return 1
	fi

	return 0
}

# 提取根域名
extract_root_domain() {
	local full_domain="$1"
	# 简单实现：取最后两部分
	# 对于 cdn.api.example.com，返回 example.com
	echo "${full_domain}" | awk -F. '{print $(NF-1)"."$NF}'
}

# 获取或验证 Zone ID
_GET_ZONE_ID() {
	if [[ -n "${ZONE_ID}" ]]; then
		log_info "使用配置文件中的 Zone ID: ${ZONE_ID}"
		return 0
	fi

	log_info "Zone ID 未配置，正在自动获取..."

	local root_domain=$(extract_root_domain "${NAME}")
	log_info "根域名: ${root_domain}"

	local response
	if [[ "${AUTH_MODE}" == "token" ]]; then
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
			-H "Authorization: Bearer ${KEY}" \
			-H "Content-Type: application/json")
	else
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
			-H "X-Auth-Email: ${EMAIL}" \
			-H "X-Auth-Key: ${KEY}" \
			-H "Content-Type: application/json")
	fi

	if ! validate_api_response "${response}" "获取 Zone ID"; then
		exit 1
	fi

	ZONE_ID=$(echo "${response}" | jq -r '.result[0].id // empty')

	if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "null" ]]; then
		log_error "未找到域名 ${root_domain} 的 Zone ID"
		log_info "请确认域名已添加到 Cloudflare 账户"
		log_info "或手动在配置文件中指定 ZONE_ID"
		exit 1
	fi

	log_success "Zone ID: ${ZONE_ID}"
}

# 列出现有 DNS 记录
_LIST_DNS_RECORDS() {
	log_info "查询现有 DNS 记录..."

	local response
	if [[ "${AUTH_MODE}" == "token" ]]; then
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${NAME}" \
			-H "Authorization: Bearer ${KEY}" \
			-H "Content-Type: application/json")
	else
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${NAME}" \
			-H "X-Auth-Email: ${EMAIL}" \
			-H "X-Auth-Key: ${KEY}" \
			-H "Content-Type: application/json")
	fi

	if ! validate_api_response "${response}" "列出 DNS 记录"; then
		exit 1
	fi

	# 提取记录 ID 到数组
	RECORD_IDS=()
	while IFS= read -r id; do
		[[ -n "${id}" && "${id}" != "null" ]] && RECORD_IDS+=("${id}")
	done < <(echo "${response}" | jq -r '.result[].id')

	log_info "找到 ${#RECORD_IDS[@]} 条现有 ${TYPE} 记录"
}

# 删除 DNS 记录（带重试）
delete_record_with_retry() {
	local record_id="$1"
	local max_retries=3
	local retry_delay=2

	for ((i=1; i<=max_retries; i++)); do
		local response
		local http_code

		if [[ "${AUTH_MODE}" == "token" ]]; then
			response=$(curl -s -w "\n%{http_code}" -X DELETE \
				"https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
				-H "Authorization: Bearer ${KEY}" \
				-H "Content-Type: application/json")
		else
			response=$(curl -s -w "\n%{http_code}" -X DELETE \
				"https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
				-H "X-Auth-Email: ${EMAIL}" \
				-H "X-Auth-Key: ${KEY}" \
				-H "Content-Type: application/json")
		fi

		http_code=$(echo "${response}" | tail -n1)
		local body=$(echo "${response}" | sed '$d')

		if [[ "${http_code}" == "200" ]]; then
			if validate_api_response "${body}" "删除记录"; then
				return 0
			fi
		elif [[ "${http_code}" == "429" ]]; then
			log_warn "API 速率限制，等待 ${retry_delay} 秒后重试 (${i}/${max_retries})"
			sleep ${retry_delay}
			retry_delay=$((retry_delay * 2))
		else
			log_error "删除记录失败 (HTTP ${http_code})"
			return 1
		fi
	done

	log_error "删除记录失败（重试次数已用尽）"
	return 1
}

# 删除所有现有记录
_DELETE_DNS_RECORDS() {
	if [[ ${#RECORD_IDS[@]} -eq 0 ]]; then
		log_info "无需删除现有记录"
		return 0
	fi

	log_info "准备删除 ${#RECORD_IDS[@]} 条现有记录..."

	local deleted=0
	for record_id in "${RECORD_IDS[@]}"; do
		if delete_record_with_retry "${record_id}"; then
			log_success "删除记录: ${record_id}"
			((deleted++))
		else
			log_error "删除记录失败: ${record_id}"
		fi
	done

	log_info "已删除 ${deleted}/${#RECORD_IDS[@]} 条记录"
}

# 创建 DNS 记录（带重试）
create_record_with_retry() {
	local ip="$1"
	local max_retries=3
	local retry_delay=2

	for ((i=1; i<=max_retries; i++)); do
		local response
		local http_code

		local data="{\"type\":\"${TYPE}\",\"name\":\"${NAME}\",\"content\":\"${ip}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}"

		if [[ "${AUTH_MODE}" == "token" ]]; then
			response=$(curl -s -w "\n%{http_code}" -X POST \
				"https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
				-H "Authorization: Bearer ${KEY}" \
				-H "Content-Type: application/json" \
				--data "${data}")
		else
			response=$(curl -s -w "\n%{http_code}" -X POST \
				"https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
				-H "X-Auth-Email: ${EMAIL}" \
				-H "X-Auth-Key: ${KEY}" \
				-H "Content-Type: application/json" \
				--data "${data}")
		fi

		http_code=$(echo "${response}" | tail -n1)
		local body=$(echo "${response}" | sed '$d')

		if [[ "${http_code}" == "200" ]]; then
			if validate_api_response "${body}" "创建记录"; then
				return 0
			fi
		elif [[ "${http_code}" == "429" ]]; then
			log_warn "API 速率限制，等待 ${retry_delay} 秒后重试 (${i}/${max_retries})"
			sleep ${retry_delay}
			retry_delay=$((retry_delay * 2))
		else
			log_error "创建记录失败: ${ip} (HTTP ${http_code})"
			return 1
		fi
	done

	log_error "创建记录失败（重试次数已用尽）: ${ip}"
	return 1
}

# 创建新的 DNS 记录
_CREATE_DNS_RECORDS() {
	log_info "准备创建 ${#IP_LIST[@]} 条新记录..."

	local created=0
	local failed_ips=()

	for i in "${!IP_LIST[@]}"; do
		local ip="${IP_LIST[$i]}"
		log_info "创建新 DNS 记录 ($((i+1))/${#IP_LIST[@]})..."

		if create_record_with_retry "${ip}"; then
			log_success "创建记录: ${ip}"
			((created++))
		else
			failed_ips+=("${ip}")
		fi
	done

	echo "=============================="
	log_info "记录创建完成: ${created}/${#IP_LIST[@]}"

	if [[ ${#failed_ips[@]} -gt 0 ]]; then
		log_warn "失败的 IP: ${failed_ips[*]}"
	fi
}

# 验证 DNS 记录
_VERIFY_RECORDS() {
	log_info "验证 DNS 记录..."

	local response
	if [[ "${AUTH_MODE}" == "token" ]]; then
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${NAME}" \
			-H "Authorization: Bearer ${KEY}" \
			-H "Content-Type: application/json")
	else
		response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${NAME}" \
			-H "X-Auth-Email: ${EMAIL}" \
			-H "X-Auth-Key: ${KEY}" \
			-H "Content-Type: application/json")
	fi

	if ! validate_api_response "${response}" "验证记录"; then
		exit 1
	fi

	local count=$(echo "${response}" | jq -r '.result | length')
	log_info "当前共有 ${count} 条 ${TYPE} 记录"

	# 显示所有记录
	echo ""
	log_info "DNS 记录列表:"
	echo "${response}" | jq -r '.result[] | "  - \(.content) (ID: \(.id))"'
}

# 打印总结
_PRINT_SUMMARY() {
	echo ""
	echo "=============================="
	log_success "更新完成！"
	echo "=============================="
	log_info "域名: ${NAME}"
	log_info "记录类型: ${TYPE}"
	log_info "成功创建: ${#IP_LIST[@]} 条记录"
	log_info "最快 IP: ${IP_LIST[0]}"
	echo "=============================="
}

# 主函数
main() {
	echo "=============================="
	echo "CloudflareSpeedTest 多 IP DNS 更新"
	echo "=============================="

	# 获取锁
	acquire_lock

	# 检查依赖
	check_dependencies

	# 读取配置
	_READ_CONFIG

	# 确保 CFST 可用（自动检测或下载）
	ensure_cfst "${CFST_VERSION}"

	# 切换到 CFST 目录
	cd "${CFST_PATH}" || { log_error "无法进入目录: ${CFST_PATH}"; exit 1; }

	# 运行 CFST 并提取 IP
	_RUN_CFST
	_EXTRACT_IPS

	# 获取 Zone ID
	_GET_ZONE_ID

	# 管理 DNS 记录
	_LIST_DNS_RECORDS
	_DELETE_DNS_RECORDS
	_CREATE_DNS_RECORDS

	# 验证和总结
	_VERIFY_RECORDS
	_PRINT_SUMMARY
}

# 解析命令行参数
parse_arguments "$@"

# 运行主函数
main
