#!/usr/bin/env bash
# CloudflareSpeedTest 多 IP DNS 更新 - 环境变量示例

# 设置环境变量
export KEY="dh_BH_6fqWX07ErU-J_N8semqnsJ1D4ngNSEWa5X"
export NAME="szddns.coderyzun.cyou"
export TYPE="A"
export TTL="60"
export PROXIED="false"
export IP_COUNT="10"

# 可选配置
# export ZONE_ID="your_zone_id"           # 留空则自动获取
# export CFST_VERSION="v2.3.4"            # CFST 版本
# export CFST_PARAMS="-n 200 -t 4"        # CFST 运行参数

# 运行脚本（不需要配置文件）
./cfst_ddns_multi.sh
