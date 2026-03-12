#!/bin/bash

# ====================================
# GCP 实例 / VPC 快捷管理脚本(最终全量版)
# ====================================

set -u

# ---------- 默认变量 ----------
DEFAULT_VPC_NAME="v4v6"
DEFAULT_VM_NAME="hide217"
DEFAULT_MACHINE_TYPE="e2-micro"
DEFAULT_DISK_SIZE="10GB"
DEFAULT_IMAGE_PROJECT="debian-cloud"
DEFAULT_IMAGE_FAMILY="debian-12"
DEFAULT_SSH_PORT="56013"

PROJECT=""
VPC_NAME="$DEFAULT_VPC_NAME"
SUBNET_NAME=""
SUBNET_REGION=""
ZONE=""
NAME=""

FW_RULE_V4IN=""
FW_RULE_V4OUT=""
FW_RULE_V6IN=""
FW_RULE_V6OUT=""

# ---------- 颜色 ----------
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
CYAN="\033[96m"
RESET="\033[0m"

# ---------- 区域列表 ----------
REGION_LIST=(
    "asia-east1"
    "asia-east2"
    "asia-northeast1"
    "asia-northeast2"
    "asia-northeast3"
    "asia-south1"
    "asia-south2"
    "asia-southeast1"
    "asia-southeast2"
    "asia-southeast3"
    "australia-southeast1"
    "australia-southeast2"
)

# ---------- 区域 IPv4 段 ----------
declare -A REGION_CIDR_MAP=(
    ["asia-east1"]="10.140.0.0/20"
    ["asia-east2"]="10.170.0.0/20"
    ["asia-northeast1"]="10.146.0.0/20"
    ["asia-northeast2"]="10.174.0.0/20"
    ["asia-northeast3"]="10.178.0.0/20"
    ["asia-south1"]="10.160.0.0/20"
    ["asia-south2"]="10.190.0.0/20"
    ["asia-southeast1"]="10.148.0.0/20"
    ["asia-southeast2"]="10.184.0.0/20"
    ["asia-southeast3"]="10.232.0.0/20"
    ["australia-southeast1"]="10.152.0.0/20"
    ["australia-southeast2"]="10.192.0.0/20"
)

# ---------- 区域简称 ----------
declare -A REGION_ALIAS_MAP=(
    ["asia-east1"]="tw"
    ["asia-east2"]="hk"
    ["asia-northeast1"]="jp1"
    ["asia-northeast2"]="jp2"
    ["asia-northeast3"]="kr"
    ["asia-south1"]="in1"
    ["asia-south2"]="in2"
    ["asia-southeast1"]="sg"
    ["asia-southeast2"]="id"
    ["asia-southeast3"]="th"
    ["australia-southeast1"]="au1"
    ["australia-southeast2"]="au2"
)

# ---------- 基础检查 ----------
check_gcloud() {
    if ! command -v gcloud >/dev/null 2>&1; then
        echo -e "${RED}[错误] 未检测到 gcloud,请先安装并登录 Google Cloud SDK。${RESET}"
        exit 1
    fi
}

# ---------- 自动获取当前项目 ----------
auto_get_project() {
    PROJECT=$(gcloud config get-value project 2>/dev/null | tr -d '\r')
    if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
        return 1
    fi
    return 0
}

# ---------- 显示当前项目 ----------
show_current_project() {
    if auto_get_project; then
        echo -e "当前默认项目: ${CYAN}${PROJECT}${RESET}"
    else
        echo -e "当前默认项目: ${YELLOW}(未设置)${RESET}"
    fi
}

# ---------- 自动启用 API ----------
ensure_required_apis() {
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 当前未设置默认项目,无法启用 API。${RESET}"
        return 1
    fi

    local apis=("compute.googleapis.com")
    local api enabled

    echo "------------------------------------"
    echo ">>> 检查并自动启用所需 API ..."
    for api in "${apis[@]}"; do
        enabled=$(gcloud services list --enabled --project="$PROJECT" \
            --filter="config.name:${api}" \
            --format="value(config.name)" 2>/dev/null)

        if [ "$enabled" = "$api" ]; then
            echo -e "${GREEN}已启用: $api${RESET}"
        else
            echo -e "${YELLOW}正在启用: $api${RESET}"
            gcloud services enable "$api" --project="$PROJECT"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}启用成功: $api${RESET}"
            else
                echo -e "${RED}[错误] 启用失败: $api${RESET}"
                return 1
            fi
        fi
    done
    echo "------------------------------------"
    return 0
}

# ---------- 创建项目 ----------
create_project_interactive() {
    echo -e "\n>>> 准备创建新项目..."
    read -p "请输入新的项目 ID(全局唯一): " new_project_id
    if [ -z "$new_project_id" ]; then
        echo -e "${YELLOW}[错误] 项目 ID 不能为空。${RESET}"
        return 1
    fi

    read -p "请输入项目名称(可留空默认同项目ID): " new_project_name
    new_project_name=${new_project_name:-$new_project_id}

    gcloud projects create "$new_project_id" --name="$new_project_name"
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误] 项目创建失败。${RESET}"
        return 1
    fi

    PROJECT="$new_project_id"
    echo -e "${GREEN}>>> 项目创建成功: $PROJECT${RESET}"

    read -p "是否将其设置为默认项目?(Y/n): " set_choice
    if [[ -z "$set_choice" || "$set_choice" == "y" || "$set_choice" == "Y" ]]; then
        gcloud config set project "$PROJECT" >/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}>>> 默认项目已设置为: $PROJECT${RESET}"
            ensure_required_apis
        fi
    fi
    return 0
}

# ---------- 选择项目 ----------
select_project() {
    echo -e "\n>>> 正在获取账号下的项目列表..."
    local projects_data
    projects_data=$(gcloud projects list --format="value(projectId,name)" 2>/dev/null)

    if [ -z "$projects_data" ]; then
        echo -e "${YELLOW}[提示] 当前账号下没有查询到项目。${RESET}"
        read -p "是否现在创建新项目?(y/N): " create_choice
        if [[ "$create_choice" == "y" || "$create_choice" == "Y" ]]; then
            create_project_interactive
            return $?
        fi
        return 1
    fi

    local pids=()
    local i=1
    local pid pname

    echo "------------------------------------"
    echo "发现以下项目,请选择:"
    while read -r pid pname; do
        [ -z "$pid" ] && continue
        pids+=("$pid")
        echo "  [$i] 项目ID: ${CYAN}$pid${RESET} | 项目名: $pname"
        ((i++))
    done <<< "$projects_data"
    echo "  [c] 创建新项目"
    echo "  [0] 返回主菜单"
    echo "------------------------------------"

    local choice
    while true; do
        read -p "请输入对应编号: " choice
        if [[ "$choice" == "0" ]]; then
            return 1
        elif [[ "$choice" == "c" || "$choice" == "C" ]]; then
            create_project_interactive
            return $?
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            PROJECT="${pids[$((choice-1))]}"
            echo -e "${GREEN}>>> 已选择项目: $PROJECT${RESET}"
            return 0
        else
            echo -e "${YELLOW}[错误] 输入无效,请重试。${RESET}"
        fi
    done
}

# ---------- 区域菜单 ----------
print_region_menu() {
    echo "【亚太区域列表】"
    local i=1
    local region
    for region in "${REGION_LIST[@]}"; do
        echo "  [$i] $region    ${REGION_CIDR_MAP[$region]}    别名:${REGION_ALIAS_MAP[$region]}"
        ((i++))
    done
    echo "------------------------------------"
}

# ---------- 读取区域多选 ----------
read_regions_multi() {
    local region_choices
    read -p "请输入区域编号,可多选(如 1,2,4;直接回车默认 2=asia-east2): " region_choices
    region_choices=${region_choices:-2}

    local cleaned
    cleaned=$(echo "$region_choices" | tr -d ' ')

    local selected_regions=()
    local nums=()
    local n
    IFS=',' read -ra nums <<< "$cleaned"

    for n in "${nums[@]}"; do
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#REGION_LIST[@]}" ]; then
            selected_regions+=("${REGION_LIST[$((n-1))]}")
        else
            echo -e "${YELLOW}[警告] 已忽略无效编号: $n${RESET}" >&2
        fi
    done

    if [ "${#selected_regions[@]}" -eq 0 ]; then
        selected_regions=("asia-east2")
    fi

    printf '%s\n' "${selected_regions[@]}"
}

# ---------- 构建防火墙规则名 ----------
build_firewall_rule_names() {
    local vpc="$1"
    FW_RULE_V4IN="${vpc}-v4in"
    FW_RULE_V4OUT="${vpc}-v4out"
    FW_RULE_V6IN="${vpc}-v6in"
    FW_RULE_V6OUT="${vpc}-v6out"
}

# ---------- 清洗资源名 ----------
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ---------- 选择已有实例 ----------
select_existing_vm() {
    echo -e "\n>>> 正在扫描当前项目下的实例..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 当前未设置默认项目。${RESET}"
        return 1
    fi

    local instances_data
    instances_data=$(gcloud compute instances list --project="$PROJECT" --format="value(name,zone.basename())" 2>/dev/null)

    if [ -z "$instances_data" ]; then
        echo -e "${YELLOW}[提示] 当前项目下没有找到任何实例。${RESET}"
        return 1
    fi

    local names=()
    local zones=()
    local i=1
    local name zone

    echo "------------------------------------"
    echo "发现以下实例,请选择要操作的机器:"
    while read -r name zone; do
        [ -z "$name" ] && continue
        names+=("$name")
        zones+=("$zone")
        echo -e "  [$i] 实例名: ${CYAN}$name${RESET} (可用区: $zone)"
        ((i++))
    done <<< "$instances_data"

    echo "  [0] 取消操作并返回主菜单"
    echo "------------------------------------"

    local choice
    while true; do
        read -p "请输入对应的数字 [0-$((i-1))]: " choice
        if [[ "$choice" == "0" ]]; then
            echo "操作已取消。"
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            NAME="${names[$((choice-1))]}"
            ZONE="${zones[$((choice-1))]}"
            echo -e "${GREEN}>>> 已锁定目标: $NAME ($ZONE)${RESET}"
            return 0
        else
            echo -e "${YELLOW}[错误] 输入无效,请重新输入数字。${RESET}"
        fi
    done
}

# ---------- 选择 VPC 下子网 ----------
select_subnet_in_vpc() {
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 当前未设置默认项目。${RESET}"
        return 1
    fi

    read -p "请输入目标 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}

    local subnet_data
    subnet_data=$(gcloud compute networks subnets list \
        --project="$PROJECT" \
        --filter="network~.*/${VPC_NAME}$" \
        --format="value(name,region.basename())" 2>/dev/null)

    if [ -z "$subnet_data" ]; then
        echo -e "${YELLOW}[提示] 在 VPC [$VPC_NAME] 下没有找到任何子网,请先创建。${RESET}"
        return 1
    fi

    local snames=()
    local sregions=()
    local i=1
    local sname sregion

    echo "------------------------------------"
    echo "发现以下子网,请选择:"
    while read -r sname sregion; do
        [ -z "$sname" ] && continue
        snames+=("$sname")
        sregions+=("$sregion")
        echo -e "  [$i] 子网名: ${CYAN}$sname${RESET} | 区域: $sregion"
        ((i++))
    done <<< "$subnet_data"

    echo "  [0] 返回主菜单"
    echo "------------------------------------"

    local choice
    while true; do
        read -p "请输入对应数字 [0-$((i-1))]: " choice
        if [[ "$choice" == "0" ]]; then
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            SUBNET_NAME="${snames[$((choice-1))]}"
            SUBNET_REGION="${sregions[$((choice-1))]}"
            echo -e "${GREEN}>>> 已选择子网: $SUBNET_NAME ($SUBNET_REGION)${RESET}"
            return 0
        else
            echo -e "${YELLOW}[错误] 输入无效,请重试。${RESET}"
        fi
    done
}

# ---------- 选择 region 下可用 zone ----------
select_zone_from_region() {
    local region="$1"
    echo "------------------------------------"
    echo ">>> 正在获取 region [$region] 下的可用 zone ..."

    local zone_data
    zone_data=$(gcloud compute zones list \
        --project="$PROJECT" \
        --filter="region:(${region})" \
        --format="value(name,status)" 2>/dev/null)

    if [ -z "$zone_data" ]; then
        echo -e "${RED}[错误] 未获取到区域 [$region] 下的可用 zone。${RESET}"
        return 1
    fi

    local zones=()
    local i=1
    local zname zstatus

    echo "可用区列表:"
    while read -r zname zstatus; do
        [ -z "$zname" ] && continue
        zones+=("$zname")
        echo "  [$i] $zname   状态:$zstatus"
        ((i++))
    done <<< "$zone_data"

    echo "------------------------------------"
    local choice
    while true; do
        read -p "请选择可用区编号 [默认: 1]: " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
            ZONE="${zones[$((choice-1))]}"
            echo -e "${GREEN}>>> 已选择可用区: $ZONE${RESET}"
            return 0
        else
            echo -e "${YELLOW}[错误] 输入无效,请重新选择。${RESET}"
        fi
    done
}

# ---------- 功能1:查看项目 ----------
func_view_projects() {
    echo -e "\n>>> 查看账号下所有项目..."
    gcloud projects list
    echo
}

# ---------- 功能2:设置默认项目 ----------
func_set_default_project() {
    echo -e "\n>>> 设置默认项目..."
    if ! select_project; then return; fi

    gcloud config set project "$PROJECT"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> 默认项目已设置为: $PROJECT${RESET}"
        ensure_required_apis
    else
        echo -e "${RED}[错误] 设置默认项目失败。${RESET}"
    fi
    echo
}

# ---------- 功能3:创建 VPC 和双栈子网 ----------
func_create_vpc_subnets() {
    echo -e "\n>>> 准备创建 VPC 网络和双栈子网..."
    if ! auto_get_project >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        if ! select_project; then return; fi
        gcloud config set project "$PROJECT" >/dev/null
    fi

    if ! ensure_required_apis; then
        echo -e "${RED}[错误] API 启用失败,无法继续。${RESET}"
        return
    fi

    read -p "请输入 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}

    echo "------------------------------------"
    print_region_menu

    local selected_regions=()
    mapfile -t selected_regions < <(read_regions_multi)

    if [ "${#selected_regions[@]}" -eq 0 ]; then
        echo -e "${RED}[错误] 未获取到有效区域,操作终止。${RESET}"
        return
    fi

    echo "你选择的区域: ${selected_regions[*]}"
    echo "------------------------------------"

    echo "-> 检查 VPC 是否已存在..."
    if gcloud compute networks describe "$VPC_NAME" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] VPC $VPC_NAME 已存在,跳过创建。${RESET}"
    else
        echo "-> 正在创建 VPC(自定义模式 + 自动分配 ULA 内部 IPv6 范围)..."
        gcloud compute networks create "$VPC_NAME" \
            --project="$PROJECT" \
            --subnet-mode=custom \
            --enable-ula-internal-ipv6 \
            --quiet >/dev/null

        if [ $? -ne 0 ]; then
            echo -e "${RED}[错误] VPC 创建失败。${RESET}"
            return
        fi
        echo -e "${GREEN}>>> VPC 创建成功: $VPC_NAME${RESET}"
    fi

    echo "------------------------------------"
    echo "-> 开始创建双栈子网..."

    local idx=1
    local total="${#selected_regions[@]}"
    local region cidr alias final_subnet_name
    local subnet_ok=0
    local subnet_fail=0

    for region in "${selected_regions[@]}"; do
        cidr="${REGION_CIDR_MAP[$region]:-}"
        alias="${REGION_ALIAS_MAP[$region]:-}"
        final_subnet_name="$alias"

        if [ -z "$cidr" ]; then
            echo -e "${RED}[错误] 区域 [$region] 没有匹配到 IPv4 CIDR,已跳过。${RESET}"
            ((subnet_fail++))
            ((idx++))
            continue
        fi

        if [ -z "$alias" ]; then
            echo -e "${RED}[错误] 区域 [$region] 没有定义简称,已跳过。${RESET}"
            ((subnet_fail++))
            ((idx++))
            continue
        fi

        echo "[$idx/$total] 创建子网: $final_subnet_name | 区域: $region | IPv4: $cidr"

        if gcloud compute networks subnets describe "$final_subnet_name" \
            --project="$PROJECT" \
            --region="$region" >/dev/null 2>&1; then
            echo -e "${YELLOW}[提示] 子网 $final_subnet_name ($region) 已存在,跳过。${RESET}"
            ((subnet_ok++))
            ((idx++))
            continue
        fi

        gcloud compute networks subnets create "$final_subnet_name" \
            --project="$PROJECT" \
            --network="$VPC_NAME" \
            --region="$region" \
            --range="$cidr" \
            --stack-type=IPV4_IPV6 \
            --ipv6-access-type=EXTERNAL \
            --quiet >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}>>> 子网创建成功: $final_subnet_name ($region)${RESET}"
            ((subnet_ok++))
        else
            echo -e "${RED}[错误] 子网创建失败: $final_subnet_name ($region)${RESET}"
            ((subnet_fail++))
        fi
        ((idx++))
    done

    echo "------------------------------------"
    echo -e "${GREEN}>>> VPC / 双栈子网处理完成。成功: ${subnet_ok} ,失败: ${subnet_fail}${RESET}\n"
}

# ---------- 功能4:创建 VM ----------
func_create_vm() {
    echo -e "\n>>> 准备创建虚拟机..."
    if ! auto_get_project >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        if ! select_project; then return; fi
        gcloud config set project "$PROJECT" >/dev/null
    fi

    if ! ensure_required_apis; then
        echo -e "${RED}[错误] API 启用失败,无法继续。${RESET}"
        return
    fi

    if ! select_subnet_in_vpc; then return; fi
    if ! select_zone_from_region "$SUBNET_REGION"; then return; fi

    read -p "请输入新实例名称 [默认: ${DEFAULT_VM_NAME}]: " NAME
    NAME=${NAME:-$DEFAULT_VM_NAME}

    echo "------------------------------------"
    echo "请选择预配模型:"
    echo "  [1] 标准(默认)"
    echo "  [2] Spot"
    read -p "请输入编号 [默认: 1]: " provision_choice
    provision_choice=${provision_choice:-1}

    local provisioning_flags=""
    local provisioning_label="STANDARD"

    if [ "$provision_choice" = "2" ]; then
        provisioning_flags="--provisioning-model=SPOT"
        provisioning_label="SPOT"
    fi

    echo "------------------------------------"
    echo ">>> 将使用如下配置:"
    echo "  项目:      $PROJECT"
    echo "  VPC:       $VPC_NAME"
    echo "  子网:      $SUBNET_NAME"
    echo "  区域:      $SUBNET_REGION"
    echo "  可用区:    $ZONE"
    echo "  实例名:    $NAME"
    echo "  机型:      $DEFAULT_MACHINE_TYPE"
    echo "  磁盘:      $DEFAULT_DISK_SIZE"
    echo "  预配模型:  $provisioning_label"
    echo "------------------------------------"

    gcloud compute instances create "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$DEFAULT_MACHINE_TYPE" \
        --network-interface=subnet="$SUBNET_NAME",stack-type=IPV4_IPV6,network-tier=PREMIUM \
        --boot-disk-size="$DEFAULT_DISK_SIZE" \
        --boot-disk-type=pd-standard \
        --image-project="$DEFAULT_IMAGE_PROJECT" \
        --image-family="$DEFAULT_IMAGE_FAMILY" \
        $provisioning_flags

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> 实例 $NAME 创建完成!${RESET}\n"
    else
        echo -e "${RED}[错误] 实例创建失败,请检查配额、Billing、区域库存或 API 状态。${RESET}\n"
    fi
}

# ---------- 功能5:查看防火墙规则 ----------
func_view_firewall() {
    echo -e "\n>>> 准备获取当前项目的防火墙规则..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    read -p "请输入要查看的 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}
    build_firewall_rule_names "$VPC_NAME"

    echo "------------------------------------"
    echo "-> 正在获取 VPC [$VPC_NAME] 的防火墙规则..."
    echo

    local firewall_data
    firewall_data=$(gcloud compute firewall-rules list \
        --project="$PROJECT" \
        --filter="network~.*/${VPC_NAME}$" \
        --format="table(name:label=规则名,network.basename():label=网络,direction:label=方向,priority:label=优先级,disabled:label=禁用,sourceRanges.list():label=源范围,destinationRanges.list():label=目标范围,allowed[].map().firewall_rule().list():label=允许,denied[].map().firewall_rule().list():label=拒绝)" \
        2>/dev/null)

    if [ -z "$firewall_data" ] || [[ "$firewall_data" != *"规则名"* ]]; then
        echo -e "${YELLOW}[提示] 在 VPC [$VPC_NAME] 下没有查询到防火墙规则。${RESET}"
        echo -e "${YELLOW}[提示] 如需创建,可使用菜单 6 设置以下规则:${RESET}"
        echo -e "        ${CYAN}${FW_RULE_V4IN}${RESET}"
        echo -e "        ${CYAN}${FW_RULE_V4OUT}${RESET}"
        echo -e "        ${CYAN}${FW_RULE_V6IN}${RESET}"
        echo -e "        ${CYAN}${FW_RULE_V6OUT}${RESET}\n"
        return
    fi

    echo -e "${GREEN}【 VPC ${VPC_NAME} 的防火墙规则列表 】${RESET}"
    echo "$firewall_data"
    echo -e "==========================================================\n"
}

# ---------- 功能6:设置防火墙规则 ----------
func_setup_firewall() {
    echo -e "\n>>> 准备设置防火墙规则..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    read -p "请输入目标 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}
    build_firewall_rule_names "$VPC_NAME"

    echo "------------------------------------"
    echo "-> 检查目标 VPC 是否存在..."
    if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${RED}[错误] VPC [$VPC_NAME] 不存在,请先创建 VPC 和子网。${RESET}"
        return
    fi

    echo "-> 正在创建 IPv4 入站规则 (${FW_RULE_V4IN})..."
    if gcloud compute firewall-rules describe "$FW_RULE_V4IN" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 规则 ${FW_RULE_V4IN} 已存在,跳过。${RESET}"
    else
        gcloud compute firewall-rules create "$FW_RULE_V4IN" \
            --project="$PROJECT" \
            --direction=INGRESS \
            --priority=1000 \
            --network="$VPC_NAME" \
            --action=ALLOW \
            --rules=all \
            --source-ranges=0.0.0.0/0
        [ $? -eq 0 ] && echo -e "${GREEN}>>> ${FW_RULE_V4IN} 创建成功${RESET}" || echo -e "${RED}[错误] ${FW_RULE_V4IN} 创建失败${RESET}"
    fi

    echo "-> 正在创建 IPv4 出站规则 (${FW_RULE_V4OUT})..."
    if gcloud compute firewall-rules describe "$FW_RULE_V4OUT" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 规则 ${FW_RULE_V4OUT} 已存在,跳过。${RESET}"
    else
        gcloud compute firewall-rules create "$FW_RULE_V4OUT" \
            --project="$PROJECT" \
            --direction=EGRESS \
            --priority=1000 \
            --network="$VPC_NAME" \
            --action=ALLOW \
            --rules=all \
            --destination-ranges=0.0.0.0/0
        [ $? -eq 0 ] && echo -e "${GREEN}>>> ${FW_RULE_V4OUT} 创建成功${RESET}" || echo -e "${RED}[错误] ${FW_RULE_V4OUT} 创建失败${RESET}"
    fi

    echo "-> 正在创建 IPv6 入站规则 (${FW_RULE_V6IN})..."
    if gcloud compute firewall-rules describe "$FW_RULE_V6IN" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 规则 ${FW_RULE_V6IN} 已存在,跳过。${RESET}"
    else
        gcloud compute firewall-rules create "$FW_RULE_V6IN" \
            --project="$PROJECT" \
            --direction=INGRESS \
            --priority=1000 \
            --network="$VPC_NAME" \
            --action=ALLOW \
            --rules=all \
            --source-ranges=::/0
        [ $? -eq 0 ] && echo -e "${GREEN}>>> ${FW_RULE_V6IN} 创建成功${RESET}" || echo -e "${RED}[错误] ${FW_RULE_V6IN} 创建失败${RESET}"
    fi

    echo "-> 正在创建 IPv6 出站规则 (${FW_RULE_V6OUT})..."
    if gcloud compute firewall-rules describe "$FW_RULE_V6OUT" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${YELLOW}[提示] 规则 ${FW_RULE_V6OUT} 已存在,跳过。${RESET}"
    else
        gcloud compute firewall-rules create "$FW_RULE_V6OUT" \
            --project="$PROJECT" \
            --direction=EGRESS \
            --priority=1000 \
            --network="$VPC_NAME" \
            --action=ALLOW \
            --rules=all \
            --destination-ranges=::/0
        [ $? -eq 0 ] && echo -e "${GREEN}>>> ${FW_RULE_V6OUT} 创建成功${RESET}" || echo -e "${RED}[错误] ${FW_RULE_V6OUT} 创建失败${RESET}"
    fi

    echo -e "${GREEN}>>> 防火墙规则设置完成!${RESET}\n"
}

# ---------- 功能7:动/静态 IPv4 切换 ----------
func_toggle_ip_mode() {
    echo -e "\n>>> 准备进行 IPv4 动/静态切换..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    if ! select_existing_vm; then
        return
    fi

    local nic_name access_config_name current_ip network_tier region static_addr_name
    nic_name=$(gcloud compute instances describe "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --format="value(networkInterfaces[0].name)" 2>/dev/null)

    access_config_name=$(gcloud compute instances describe "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].name)" 2>/dev/null)

    current_ip=$(gcloud compute instances describe "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

    network_tier=$(gcloud compute instances describe "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].networkTier)" 2>/dev/null)

    region="${ZONE%-*}"
    network_tier=${network_tier:-PREMIUM}

    if [ -z "$nic_name" ] || [ -z "$access_config_name" ]; then
        echo -e "${RED}[错误] 未检测到实例的外部 IPv4 配置,无法切换。${RESET}"
        return
    fi

    static_addr_name=$(gcloud compute addresses list \
        --project="$PROJECT" \
        --regions="$region" \
        --filter="address=${current_ip}" \
        --format="value(name)" 2>/dev/null | head -n1)

    echo "------------------------------------"
    echo "实例名: $NAME"
    echo "可用区: $ZONE"
    echo "区域: $region"
    echo "当前公网IPv4: ${current_ip:-无}"
    if [ -n "$static_addr_name" ]; then
        echo "当前IPv4类型: 静态IP ($static_addr_name)"
    else
        echo "当前IPv4类型: 动态IP"
    fi
    echo "网络层级: $network_tier"
    echo "------------------------------------"
    echo "请选择操作:"
    echo "  [1] 动态IP -> 静态IP"
    echo "  [2] 静态IP -> 动态IP"
    echo "  [0] 返回主菜单"

    local choice
    read -p "请输入编号 [0-2]: " choice

    case "$choice" in
        1)
            if [ -z "$current_ip" ]; then
                echo -e "${RED}[错误] 当前实例没有公网 IPv4,无法直接转为静态。${RESET}"
                return
            fi

            if [ -n "$static_addr_name" ]; then
                echo -e "${YELLOW}[提示] 当前公网 IPv4 已经是静态IP,无需转换。${RESET}"
                return
            fi

            local new_addr_name
            new_addr_name=$(sanitize_name "${NAME}-${region}-ipv4")
            if gcloud compute addresses describe "$new_addr_name" --project="$PROJECT" --region="$region" >/dev/null 2>&1; then
                new_addr_name="${new_addr_name}-$(date +%s)"
            fi

            echo "-> 正在将当前动态 IPv4 保留为静态地址: $new_addr_name"
            gcloud compute addresses create "$new_addr_name" \
                --project="$PROJECT" \
                --region="$region" \
                --addresses="$current_ip" \
                --network-tier="$network_tier"

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}>>> 已成功切换为静态IP: $current_ip (资源名: $new_addr_name)${RESET}"
            else
                echo -e "${RED}[错误] 动态IP 转 静态IP 失败。${RESET}"
            fi
            ;;
        2)
            if [ -z "$current_ip" ]; then
                echo -e "${RED}[错误] 当前实例没有公网 IPv4。${RESET}"
                return
            fi

            if [ -z "$static_addr_name" ]; then
                echo -e "${YELLOW}[提示] 当前公网 IPv4 已经是动态IP,无需转换。${RESET}"
                return
            fi

            echo -e "${YELLOW}[警告] 静态IP 转为动态IP 时,公网 IPv4 可能会发生变化。${RESET}"
            read -p "确认继续吗?(y/N): " confirm_change
            if [[ "$confirm_change" != "y" && "$confirm_change" != "Y" ]]; then
                echo "已取消。"
                return
            fi

            echo "-> 正在移除当前外部访问配置..."
            gcloud compute instances delete-access-config "$NAME" \
                --project="$PROJECT" \
                --zone="$ZONE" \
                --access-config-name="$access_config_name" \
                --network-interface="$nic_name"

            if [ $? -ne 0 ]; then
                echo -e "${RED}[错误] 删除旧访问配置失败,操作终止。${RESET}"
                return
            fi

            echo "-> 正在重新添加动态公网 IPv4 ..."
            gcloud compute instances add-access-config "$NAME" \
                --project="$PROJECT" \
                --zone="$ZONE" \
                --access-config-name="$access_config_name" \
                --network-interface="$nic_name" \
                --network-tier="$network_tier"

            if [ $? -ne 0 ]; then
                echo -e "${RED}[错误] 添加动态公网 IPv4 失败,请手动检查实例网络配置。${RESET}"
                return
            fi

            echo "-> 正在释放旧静态IP资源: $static_addr_name"
            gcloud compute addresses delete "$static_addr_name" \
                --project="$PROJECT" \
                --region="$region" \
                --quiet

            echo -e "${GREEN}>>> 已切换为动态IP。${RESET}"
            ;;
        0)
            echo "已取消。"
            ;;
        *)
            echo -e "${YELLOW}[错误] 输入无效。${RESET}"
            ;;
    esac

    echo
}

# ---------- 功能8:更换 Debian 12 镜像源 ----------
func_change_apt_source() {
    echo -e "\n>>> 准备更换 Debian 12 镜像源..."
    if ! select_existing_vm; then return; fi

    gcloud compute ssh "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --command="sudo bash -c 'cat > /etc/apt/sources.list.d/debian.sources <<EOF && rm -rf /var/lib/apt/lists/* && apt update
Types: deb deb-src
URIs: http://mirrors.mit.edu/debian
Suites: bookworm bookworm-updates bookworm-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://mirrors.ocf.berkeley.edu/debian-security
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF'"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> Debian 12 镜像源更换成功!${RESET}"
    else
        echo -e "${YELLOW}>>> 镜像源更换出现错误,请检查网络连接。${RESET}"
    fi
    echo
}

# ---------- 功能9:一键配置 SSH ----------
func_setup_ssh() {
    echo -e "\n>>> 准备配置 SSH 环境..."
    if ! select_existing_vm; then return; fi

    local ROOT_PASS ROOT_PASS_CONFIRM
    while true; do
        read -s -p "请设置新的 Root 密码 (输入时不可见): " ROOT_PASS
        echo
        read -s -p "请再次输入密码以确认: " ROOT_PASS_CONFIRM
        echo
        if [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ]; then
            if [ -z "$ROOT_PASS" ]; then
                echo -e "${YELLOW}[错误] 密码不能为空,请重试!${RESET}"
            else
                break
            fi
        else
            echo -e "${YELLOW}[错误] 两次输入的密码不一致,请重试!${RESET}"
        fi
    done

    gcloud compute ssh "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --command="sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config && \
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' /etc/ssh/sshd_config && \
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config && \
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true && \
sudo sed -i 's/^#\?Port.*/Port ${DEFAULT_SSH_PORT}/g' /etc/ssh/sshd_config && \
echo \"root:${ROOT_PASS}\" | sudo chpasswd && \
sudo systemctl restart ssh || sudo systemctl restart sshd"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> SSH 配置成功!${RESET}"
        echo -e ">>> 用户名: ${CYAN}root${RESET}"
        echo -e ">>> 端口: ${CYAN}${DEFAULT_SSH_PORT}${RESET}"
    else
        echo -e "${YELLOW}>>> SSH 配置过程中可能出现错误,请检查网络连接。${RESET}"
    fi
    echo
}

# ---------- 功能10:查看当前项目下所有实例信息 ----------
func_view_vm() {
    echo -e "\n>>> 准备扫描当前项目下的所有实例信息..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    echo "------------------------------------"
    echo -e "${GREEN}【 实例详细信息列表 】${RESET}"

    local instances_data
    instances_data=$(gcloud compute instances list \
        --project="$PROJECT" \
        --format="value(name,zone.basename())" 2>/dev/null)

    if [ -z "$instances_data" ]; then
        echo -e "${YELLOW}[提示] 当前项目下没有实例。${RESET}"
        echo
        return
    fi

    local name zone
    while read -r name zone; do
        [ -z "$name" ] && continue

        local status
        local public_ipv4
        local public_ipv6
        local disk_gb
        local image_name
        local provisioning_model
        local network_tier

        status=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(status)" 2>/dev/null)

        public_ipv4=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

        public_ipv6=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(networkInterfaces[0].ipv6AccessConfigs[0].externalIpv6)" 2>/dev/null)

        disk_gb=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(disks[0].diskSizeGb)" 2>/dev/null)

        image_name=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(disks[0].licenses[0].basename())" 2>/dev/null)

        provisioning_model=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(scheduling.provisioningModel)" 2>/dev/null)

        network_tier=$(gcloud compute instances describe "$name" \
            --project="$PROJECT" \
            --zone="$zone" \
            --format="value(networkInterfaces[0].accessConfigs[0].networkTier)" 2>/dev/null)

        provisioning_model=${provisioning_model:-STANDARD}
        network_tier=${network_tier:-PREMIUM}
        public_ipv4=${public_ipv4:-"-"}
        public_ipv6=${public_ipv6:-"-"}
        disk_gb=${disk_gb:-"-"}
        image_name=${image_name:-"-"}
        status=${status:-"-"}

        echo "实例名称: $name"
        echo "可用区: $zone"
        echo "公网IPv4: $public_ipv4"
        echo "公网IPv6: $public_ipv6"
        echo "磁盘GB: $disk_gb"
        echo "系统: $image_name"
        echo "预配模型: $provisioning_model"
        echo "网络层级: $network_tier"
        echo "状态: $status"
        echo "=========================================================="
    done <<< "$instances_data"

    echo
}

# ---------- 功能11:删除实例 ----------
func_delete_vm() {
    echo -e "\n${RED}>>> [警告] 准备执行删除实例操作...${RESET}"
    if ! select_existing_vm; then return; fi

    read -p "确定要彻底删除实例 [$NAME] 吗?(y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "已取消删除。"
        return
    fi

    gcloud compute instances delete "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> 实例 $NAME 已彻底删除!${RESET}\n"
    else
        echo -e "${RED}[错误] 实例删除失败。${RESET}\n"
    fi
}

# ---------- 功能12:删除 VPC/子网 ----------
func_delete_vpc_subnets() {
    echo -e "\n>>> 准备删除 VPC/子网..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    read -p "请输入目标 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}

    if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT" >/dev/null 2>&1; then
        echo -e "${RED}[错误] VPC [$VPC_NAME] 不存在。${RESET}"
        return
    fi

    echo "------------------------------------"
    echo "请选择操作:"
    echo "  [1] 删除指定子网"
    echo "  [2] 删除整个 VPC(会先删除该 VPC 下所有子网)"
    echo "  [0] 返回主菜单"

    local choice
    read -p "请输入编号 [0-2]: " choice

    case "$choice" in
        1)
            if ! select_subnet_in_vpc; then
                return
            fi

            read -p "确认删除子网 [$SUBNET_NAME] ($SUBNET_REGION) 吗?(y/N): " confirm_del_subnet
            if [[ "$confirm_del_subnet" != "y" && "$confirm_del_subnet" != "Y" ]]; then
                echo "已取消。"
                return
            fi

            gcloud compute networks subnets delete "$SUBNET_NAME" \
                --project="$PROJECT" \
                --region="$SUBNET_REGION" \
                --quiet

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}>>> 子网 $SUBNET_NAME 已删除。${RESET}"
            else
                echo -e "${RED}[错误] 子网删除失败。${RESET}"
            fi
            ;;
        2)
            local subnet_data
            subnet_data=$(gcloud compute networks subnets list \
                --project="$PROJECT" \
                --filter="network~.*/${VPC_NAME}$" \
                --format="value(name,region.basename())" 2>/dev/null)

            echo -e "${YELLOW}[警告] 你正在准备删除整个 VPC [$VPC_NAME]。${RESET}"
            if [ -n "$subnet_data" ]; then
                echo "该 VPC 下包含以下子网:"
                while read -r sname sregion; do
                    [ -z "$sname" ] && continue
                    echo "  - $sname ($sregion)"
                done <<< "$subnet_data"
            else
                echo "该 VPC 下没有子网。"
            fi

            read -p "确认继续删除整个 VPC 吗?(y/N): " confirm_del_vpc
            if [[ "$confirm_del_vpc" != "y" && "$confirm_del_vpc" != "Y" ]]; then
                echo "已取消。"
                return
            fi

            if [ -n "$subnet_data" ]; then
                while read -r sname sregion; do
                    [ -z "$sname" ] && continue
                    echo "-> 删除子网: $sname ($sregion)"
                    gcloud compute networks subnets delete "$sname" \
                        --project="$PROJECT" \
                        --region="$sregion" \
                        --quiet
                done <<< "$subnet_data"
            fi

            echo "-> 删除 VPC: $VPC_NAME"
            gcloud compute networks delete "$VPC_NAME" \
                --project="$PROJECT" \
                --quiet

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}>>> VPC $VPC_NAME 已删除。${RESET}"
            else
                echo -e "${RED}[错误] VPC 删除失败。${RESET}"
            fi
            ;;
        0)
            echo "已取消。"
            ;;
        *)
            echo -e "${YELLOW}[错误] 输入无效。${RESET}"
            ;;
    esac

    echo
}

# ---------- 功能13:删除 防火墙规则 ----------
func_delete_firewall_rules() {
    echo -e "\n>>> 准备删除防火墙规则..."
    if ! auto_get_project; then
        echo -e "${YELLOW}[提示] 请先设置默认项目。${RESET}"
        return
    fi

    if ! ensure_required_apis; then
        return
    fi

    read -p "请输入目标 VPC 名称 [默认: ${DEFAULT_VPC_NAME}]: " VPC_NAME
    VPC_NAME=${VPC_NAME:-$DEFAULT_VPC_NAME}
    build_firewall_rule_names "$VPC_NAME"

    echo "即将删除以下规则:"
    echo "  - $FW_RULE_V4IN"
    echo "  - $FW_RULE_V4OUT"
    echo "  - $FW_RULE_V6IN"
    echo "  - $FW_RULE_V6OUT"

    read -p "确认继续吗?(y/N): " confirm_fw_del
    if [[ "$confirm_fw_del" != "y" && "$confirm_fw_del" != "Y" ]]; then
        echo "已取消。"
        return
    fi

    local rule
    for rule in "$FW_RULE_V4IN" "$FW_RULE_V4OUT" "$FW_RULE_V6IN" "$FW_RULE_V6OUT"; do
        if gcloud compute firewall-rules describe "$rule" --project="$PROJECT" >/dev/null 2>&1; then
            echo "-> 删除规则: $rule"
            gcloud compute firewall-rules delete "$rule" \
                --project="$PROJECT" \
                --quiet
        else
            echo -e "${YELLOW}[提示] 规则不存在,跳过: $rule${RESET}"
        fi
    done

    echo -e "${GREEN}>>> 防火墙规则删除流程完成。${RESET}\n"
}

# ---------- 主菜单 ----------
main_menu() {
    while true; do
        echo "======================================================"
        echo "      GCP 实例 / VPC 快捷管理脚本  v1.6               "
        echo "======================================================"
        echo "  1. 查看账号的项目"
        echo "  2. 设置默认项目"
        echo "  3. 创建 VPC 网络和双栈子网(IPv4+IPv6)"
        echo "  4. 创建虚拟机"
        echo "  5. 查看防火墙规则"
        echo "  6. 设置防火墙规则 (VPC前缀-v4in/v4out/v6in/v6out)"
        echo "  7. 动/静态ip切换"
        echo "  8. 更换系统镜像源 (Debian 12 专用)"
        echo "  9. 一键配置 SSH (Root密码+端口${DEFAULT_SSH_PORT})"
        echo " 10. 查看当前项目下所有实例信息"
        echo " 11. 删除实例"
        echo " 12. 删除 VPC/子网"
        echo " 13. 删除 防火墙规则"
        echo "  0. 退出脚本"
        echo "======================================================"
        show_current_project
        echo "------------------------------------------------------"

        read -p "请输入对应的数字 [0-13]: " choice
        case $choice in
            1) func_view_projects ;;
            2) func_set_default_project ;;
            3) func_create_vpc_subnets ;;
            4) func_create_vm ;;
            5) func_view_firewall ;;
            6) func_setup_firewall ;;
            7) func_toggle_ip_mode ;;
            8) func_change_apt_source ;;
            9) func_setup_ssh ;;
            10) func_view_vm ;;
            11) func_delete_vm ;;
            12) func_delete_vpc_subnets ;;
            13) func_delete_firewall_rules ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo -e "\n[错误] 无效的选项,请重新输入!\n" ;;
        esac
    done
}

# ---------- 程序入口 ----------
check_gcloud
main_menu
