#!/bin/bash
#
# board.sh - 开发板测试专用：电源控制、资源清理、defconfig、U-Boot 配置
#

SCRIPT_DIR_BOARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_BOARD/lib/common.sh"

get_board_power_serial() {
    local board_name=$1
    local uboot_json_file="$COMPONENT_DIR/.uboot.json"

    if [ ! -f "$uboot_json_file" ] && [ -f "$SCRIPT_DIR_BOARD/json/uboot.json" ]; then
        uboot_json_file="$SCRIPT_DIR_BOARD/json/uboot.json"
    fi

    if [ -f "$uboot_json_file" ]; then
        local config_serial=$(jq -r ".boards[\"$board_name\"].power_serial // empty" "$uboot_json_file" 2>/dev/null)
        if [ -n "$config_serial" ]; then
            echo "$config_serial"
            return 0
        fi
    fi

    case "$board_name" in
        phytiumpi)
            echo "/dev/ttyUSB1"
            ;;
        roc-rk3568-pc)
            echo "/dev/ttyUSB2"
            ;;
        x86_64-pc)
            echo "/dev/ttyUSB4"
            ;;
        visionfive2)
            echo "/dev/ttyUSB7"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 控制开发板电源（通过 mbpoll）
control_board_power() {
    local board_name=$1
    local action=$2  # "on" 或 "off"
    local power_serial
    power_serial=$(get_board_power_serial "$board_name")

    if [ -z "$power_serial" ]; then
        log_debug "  未知开发板类型: $board_name，跳过电源控制"
        return 0
    fi

    # 检查 mbpoll 是否安装
    if ! command -v mbpoll &> /dev/null; then
        return 0
    fi

    # 检查串口是否存在
    if [ ! -e "$power_serial" ]; then
        log_warn "  电源控制串口不存在: $power_serial"
        return 0
    fi

    # 执行电源控制
    if [ "$action" == "on" ]; then
        mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v "$power_serial" 0
        sleep 3
        log "  给开发板上电... ($power_serial)"
        mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v "$power_serial" 1
    elif [ "$action" == "off" ]; then
        log "  给开发板下电... ($power_serial)"
        mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v "$power_serial" 0 &>/dev/null || true
    fi
}

# 清理开发板测试资源
cleanup_board_resources() {
    local board_name=$1
    local test_dir=$2

    log "  清理测试资源..."

    # 1. 关闭开发板电源
    if [ -f "$test_dir/.uboot.toml" ] && grep -q '^board_power_off_cmd[[:space:]]*=' "$test_dir/.uboot.toml"; then
        log "  .uboot.toml 已配置 board_power_off_cmd，跳过额外下电"
    else
        control_board_power "$board_name" "off"
    fi

    # 2. 杀掉可能残留的 cargo-osrun 进程
    local pids=$(ps aux | grep -E "cargo-osr|cargo osr" | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
        for pid in $pids; do
            log_debug "    关闭残留进程: PID=$pid"
            kill -9 $pid 2>/dev/null || true
        done
    fi

    # 3. 释放串口
    local uboot_toml_file="$COMPONENT_DIR/.uboot.toml"
    if [ -f "$uboot_toml_file" ]; then
        local serial_port=$(jq -r ".boards[\"$board_name\"].serial // empty" "$uboot_toml_file" 2>/dev/null)
        if [ -n "$serial_port" ] && [ -e "$serial_port" ]; then
            local serial_pids=$(sudo lsof -ti "$serial_port" 2>/dev/null || true)
            if [ -n "$serial_pids" ]; then
                for pid in $serial_pids; do
                    log_debug "    释放串口 $serial_port: PID=$pid"
                    sudo kill -9 $pid 2>/dev/null || true
                done
            fi
        fi
    fi

    # 等待资源释放
    sleep 2
    log "  资源清理完成"
}

# 为 Starry Board 测试准备开发板配置文件
# 参数: target_config, test_dir, log_file, status_file
setup_starry_board_files() {
    local target_config=$1
    local test_dir=$2
    local log_file=$3
    local status_file=$4
    local board_name=$(echo "$target_config" | jq -r '.board // empty')

    ensure_ostool
    if [ -z "$board_name" ]; then
        log_warn "  未配置开发板名称，跳过 Starry Board 配置文件准备"
        return 0
    fi

    local board_url="https://github.com/Starry-OS/board-config/releases/download/v0.1/${board_name}.tar.gz"
    local archive_path="/tmp/${board_name}.tar.gz"

    log "  下载 Starry 开发板配置文件: $board_url"

    if ! wget "$board_url" -O "$archive_path" >> "$log_file" 2>&1; then
        log_error "  下载开发板配置文件失败: $board_url"
        echo "failed" > "$status_file"
        return 1
    fi

    log "  解压开发板配置文件到 Starry 根目录: $test_dir"
    if ! tar -xzf "$archive_path" -C "$test_dir" >> "$log_file" 2>&1; then
        log_error "  解压开发板配置文件失败: $archive_path"
        echo "failed" > "$status_file"
        return 1
    fi

    return 0
}

# 设置 Board 测试镜像（下载、配置 kernel_path 为 memory 模式）
# 参数: target_config, target_name, test_dir, log_file, status_file
setup_board_images() {
    local target_config=$1
    local target_name=$2
    local test_dir=$3
    local log_file=$4
    local status_file=$5

    # 确保安装 ostool
    ensure_ostool

    # 创建 TFTP 目录
    local bin_dir=$(echo "$target_config" | jq -r '.test.bin_dir // "/tmp/tftp"')
    sudo mkdir -p "$bin_dir"
    sudo chmod 777 "$bin_dir"
    log "  TFTP 目录已准备: $bin_dir"

    local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
    local vmimage_name=$(echo "$target_config" | jq -r '.test.vmimage_name // empty')

    if [ -z "$vmimage_name" ]; then
        return 0
    fi

    # 下载镜像
    if ! download_images "$vmconfigs" "$vmimage_name" "$test_dir" "$log_file" "$status_file"; then
        return 1
    fi

    local IMAGE_DIR="/tmp/.axvisor-images"

    # 更新配置文件
    IFS=',' read -ra CONFIGS <<< "$vmconfigs"
    IFS=',' read -ra IMAGES <<< "$vmimage_name"

    for i in "${!CONFIGS[@]}"; do
        local img="${IMAGES[$i]}"
        img=$(echo "$img" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local config="${CONFIGS[$i]}"
        config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 更新配置文件（仅在非 --fs 模式下）
        if [ "$USE_FS_MODE" == true ]; then
            log "  --fs 模式: 跳过配置文件修改"
        elif [ -f "$test_dir/$config" ]; then
            cd "$test_dir"

            # 获取 image_location
            local image_location=$(sed -n 's/^image_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config")
            local board_name=$(echo "$target_config" | jq -r '.board')

            # Board 测试的内核文件名（与 board 同名，例如 phytiumpi）
            local kernel_name="${board_name}"

            case "$image_location" in
            "fs")
                log "  将配置从文件系统模式改为内存模式"
                # 修改 image_location 为 memory
                sed -i 's|^image_location[[:space:]]*=.*|image_location = "memory"|' "$config"
                # 更新 kernel_path 指向镜像目录中的内核文件
                sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                ;;
            "memory")
                log "  内存存储模式 - 更新 kernel_path"
                sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                ;;
            *)
                log "  未知的 image_location: $image_location，修改为 memory"
                sed -i 's|^image_location[[:space:]]*=.*|image_location = "memory"|' "$config"
                sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                ;;
            esac
        else
            log_warn "  配置文件不存在: $config"
        fi
    done
    cd "$COMPONENT_DIR"
    return 0
}

# 设置 Board defconfig 和 .build.toml
# 参数: target_config, target_name, test_dir, log_file, status_file
setup_board_defconfig() {
    local target_config=$1
    local target_name=$2
    local test_dir=$3
    local log_file=$4
    local status_file=$5

    cd "$test_dir"

    local board_name=$(echo "$target_config" | jq -r '.board')
    local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')

    # 获取客户机配置文件列表
    local vm_configs_json="["
    IFS=',' read -ra CONFIGS <<< "$vmconfigs"
    for i in "${!CONFIGS[@]}"; do
        config="${CONFIGS[$i]}"
        config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ $i -gt 0 ]; then
            vm_configs_json+=", "
        fi
        vm_configs_json+='"'"$config"'"'
    done
    vm_configs_json+="]"

    log "  执行 cargo xtask defconfig $board_name..."
    if cargo xtask defconfig "$board_name" >> "$log_file" 2>&1; then
        log_success "  Defconfig 成功"
    else
        log_error "  Defconfig 失败"
        echo "failed" > "$status_file"
        cd "$COMPONENT_DIR"
        return 1
    fi

    # 修改 .build.toml 文件
    log "  更新 .build.toml 配置..."
    local build_toml=".build.toml"

    if [ -f "$build_toml" ]; then
        if [ "$USE_FS_MODE" == true ]; then
            local fs_vm_configs=""
            case "$target_name" in
                axvisor-board-phytiumpi-arceos)
                    fs_vm_configs='["configs/vms/arceos-aarch64-e2000-smp1.toml"]'
                    ;;
                axvisor-board-phytiumpi-linux)
                    fs_vm_configs='["configs/vms/linux-aarch64-e2000-smp1.toml"]'
                    ;;
                axvisor-board-x86_64-pc-arceos)
                    fs_vm_configs='["configs/vms/arceos-x86_64-pc-smp1.toml"]'
                    ;;
                axvisor-board-roc-rk3568-pc-arceos)
                    fs_vm_configs='["configs/vms/arceos-aarch64-rk3568-smp1.toml"]'
                    ;;
                axvisor-board-roc-rk3568-pc-linux)
                    fs_vm_configs='["configs/vms/linux-aarch64-rk3568-smp1.toml"]'
                    ;;
                *)
                    log_warn "  未知目标: $target_name，使用默认 vm_configs"
                    fs_vm_configs="$vm_configs_json"
                    ;;
            esac

            # 仅替换 vm_configs，保留 features
            awk -v vm_configs="$fs_vm_configs" '
                /^vm_configs = \[/ { in_vm=1; next }
                in_vm { if(/^\]/) { in_vm=0 } next }
                /^log = / { print $0 "\nvm_configs = " vm_configs; next }
                { print }
            ' "$build_toml" > "$build_toml.tmp" && mv "$build_toml.tmp" "$build_toml"

            log_success "  .build.toml 更新完成 (--fs 模式)"
            log_debug "    - vm_configs: $fs_vm_configs"
        else
            # 非 --fs 模式: 修改 features 和 vm_configs
            awk -v vm_configs="$vm_configs_json" '
                /^features = \[/ { in_features=1; print "features = ["; print "    # \"ept-level-4\","; print "    \"dyn-plat\","; print "    \"axstd/bus-mmio\","; print "]"; next }
                in_features { if(/^\]/) { in_features=0 } next }
                /^vm_configs = \[/ { in_vm=1; next }
                in_vm { if(/^\]/) { in_vm=0 } next }
                /^log = / { print $0 "\nvm_configs = " vm_configs; next }
                { print }
            ' "$build_toml" > "$build_toml.tmp" && mv "$build_toml.tmp" "$build_toml"

            log_success "  .build.toml 更新完成"
            log_debug "    - Features 已更新"
            log_debug "    - vm_configs: $vm_configs_json"
        fi
    else
        log_error "  未找到 .build.toml 文件"
        echo "failed" > "$status_file"
        cd "$COMPONENT_DIR"
        return 1
    fi
}

# 设置 U-Boot 配置（.uboot.toml）
# 参数: target_config, test_dir
setup_uboot_config() {
    local target_config=$1
    local test_dir=$2

    cd "$test_dir"

    log "  检查 U-Boot 配置..."
    local uboot_config_file=".uboot.toml"
    local uboot_json_file="$COMPONENT_DIR/.uboot.json"
    local uboot_template_path=$(echo "$target_config" | jq -r '.test.uboot_config // empty')
    local resolved_template_path=""

    resolve_uboot_template_path() {
        local template_path=$1

        if [ -z "$template_path" ]; then
            return 1
        fi

        if [ -f "$template_path" ]; then
            echo "$template_path"
            return 0
        fi

        if [ -f "$SCRIPT_DIR_BOARD/$template_path" ]; then
            echo "$SCRIPT_DIR_BOARD/$template_path"
            return 0
        fi

        return 1
    }

    # 回退: 框架自带的 uboot.json
    if [ ! -f "$uboot_json_file" ] && [ -f "$SCRIPT_DIR_BOARD/json/uboot.json" ]; then
        uboot_json_file="$SCRIPT_DIR_BOARD/json/uboot.json"
    fi

    resolved_template_path=$(resolve_uboot_template_path "$uboot_template_path" || true)
    if [ -n "$resolved_template_path" ]; then
        uboot_template_path="$resolved_template_path"
    fi

    if [ ! -f "$uboot_config_file" ]; then
        if [ -n "$uboot_template_path" ] && [ -f "$uboot_template_path" ]; then
            cp "$uboot_template_path" "$uboot_config_file"
            log "  复用 U-Boot 模板: $uboot_template_path"
            log "  U-Boot 配置已保存到: $uboot_config_file"
            log ""
            return 0
        fi

        local serial_input=""
        local baud_rate_input=""
        local dtb_file_input=""
        local board_power_off_cmd_input=""
        local board_reset_cmd_input=""
        local network_interface_input=""
        local tftp_dir_input=""
        local success_regex_input="[]"
        local fail_regex_input="[]"
        local board_name=$(echo "$target_config" | jq -r '.board')

        # 尝试从 .uboot.json 读取配置
        if [ -f "$uboot_json_file" ]; then
            log "  从 .uboot.json 读取 $board_name 的配置..."

            # 检查配置文件中是否有该 board 的配置
            local board_config=$(jq -e ".boards[\"$board_name\"]" "$uboot_json_file" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$board_config" ]; then
                serial_input=$(echo "$board_config" | jq -r '.serial // empty')
                baud_rate_input=$(echo "$board_config" | jq -r '.baud_rate // empty')
                dtb_file_input=$(echo "$board_config" | jq -r '.dtb_file // empty')
                board_power_off_cmd_input=$(echo "$board_config" | jq -r '.board_power_off_cmd // empty')
                board_reset_cmd_input=$(echo "$board_config" | jq -r '.board_reset_cmd // empty')
                network_interface_input=$(echo "$board_config" | jq -r '.network_interface // empty')
                tftp_dir_input=$(echo "$board_config" | jq -r '.tftp_dir // empty')
                success_regex_input=$(echo "$board_config" | jq -c '.success_regex // []')
                fail_regex_input=$(echo "$board_config" | jq -c '.fail_regex // []')

                if [ -n "$serial_input" ] && [ -n "$baud_rate_input" ] && [ -n "$dtb_file_input" ]; then
                    log "  从配置文件读取到:"
                    log "  - 串口: $serial_input"
                    log "  - 波特率: $baud_rate_input"
                    log "  - DTB文件: $dtb_file_input"
                    [ -n "$network_interface_input" ] && log "  - 网络接口: $network_interface_input"
                    [ -n "$tftp_dir_input" ] && log "  - TFTP 目录: $tftp_dir_input"
                else
                    log_warn "  .uboot.json 中 $board_name 的配置不完整，将使用交互式输入"
                    serial_input=""
                    baud_rate_input=""
                    dtb_file_input=""
                fi
            else
                log_warn "  .uboot.json 中未找到 $board_name 的配置，将使用交互式输入"
            fi
        else
            log "  未找到 .uboot.json 配置文件 ($uboot_json_file)"
        fi

        # 如果从配置文件读取失败，则使用交互式输入
        if [ -z "$serial_input" ] || [ -z "$baud_rate_input" ] || [ -z "$dtb_file_input" ]; then
            log ""
            log "  ======== 配置 U-Boot 参数 ======== "
            log ""

            # 提示用户输入 serial
            echo -e "${CYAN}请输入串口设备路径 (例如: /dev/ttyUSB0):${NC}"
            read -p "> " serial_input
            serial_input="${serial_input:-/dev/ttyUSB0}"

            # 提示用户输入 baud_rate
            echo ""
            echo -e "${CYAN}请输入波特率 (例如: 115200):${NC}"
            read -p "> " baud_rate_input
            baud_rate_input="${baud_rate_input:-115200}"

            # 提示用户输入 dtb_file
            echo ""
            echo -e "${CYAN}请输入 DTB 文件路径 (例如: board/orangepi-5-plus.dtb):${NC}"
            read -p "> " dtb_file_input
            dtb_file_input="${dtb_file_input:-board/orangepi-5-plus.dtb}"

            log ""
        fi

        # 生成 .uboot.toml 文件
        cat > "$uboot_config_file" << EOF
serial = "$serial_input"
baud_rate = "$baud_rate_input"
success_regex = $success_regex_input
fail_regex = $fail_regex_input
dtb_file = "$dtb_file_input"
EOF

        if [ -n "$board_power_off_cmd_input" ]; then
            printf 'board_power_off_cmd = "%s"\n' "$board_power_off_cmd_input" >> "$uboot_config_file"
        fi
        if [ -n "$board_reset_cmd_input" ]; then
            printf 'board_reset_cmd = "%s"\n' "$board_reset_cmd_input" >> "$uboot_config_file"
        fi
        if [ -n "$network_interface_input" ] || [ -n "$tftp_dir_input" ]; then
            printf '\n[net]\n' >> "$uboot_config_file"
            [ -n "$network_interface_input" ] && printf 'interface = "%s"\n' "$network_interface_input" >> "$uboot_config_file"
            [ -n "$tftp_dir_input" ] && printf 'tftp_dir = "%s"\n' "$tftp_dir_input" >> "$uboot_config_file"
        fi

        log "  U-Boot 配置已保存到: $uboot_config_file"
        log ""
    else
        log "  使用已存在的配置文件: $uboot_config_file"
    fi
}

# 准备 Board 测试命令
# 参数: target_config
# 输出: 完整的测试命令到 stdout
prepare_board_command() {
    local target_config=$1
    local test_cmd=$(echo "$target_config" | jq -r '.test.command')
    echo "$test_cmd"
}

# 执行仅上电等待的 Board 测试
# 参数: target_config, target_name, log_file, status_file, test_dir
run_board_power_cycle_only_test() {
    local target_config=$1
    local target_name=$2
    local log_file=$3
    local status_file=$4
    local test_dir=$5
    local board_name=$(echo "$target_config" | jq -r '.board')
    local wait_seconds=$(echo "$target_config" | jq -r '.test.wait_seconds // 120')
    local serial_pid=""
    local uboot_json_file="$COMPONENT_DIR/.uboot.json"
    local serial_port=""
    local success_detected=false
    local remaining_time=$wait_seconds

    cd /home/runner/tftp/
    sudo wget https://github.com/user-attachments/files/26134564/kernel.tar.gz -O kernel.tar.gz
    sudo tar -xzf kernel.tar.gz
    log "  上电等待测试: $target_name"
    echo "[power-cycle-only] board=$board_name wait_seconds=$wait_seconds" >> "$log_file"

    if [ ! -f "$uboot_json_file" ] && [ -f "$SCRIPT_DIR_BOARD/json/uboot.json" ]; then
        uboot_json_file="$SCRIPT_DIR_BOARD/json/uboot.json"
    fi
    if [ -f "$uboot_json_file" ]; then
        serial_port=$(jq -r ".boards[\"$board_name\"].serial // empty" "$uboot_json_file" 2>/dev/null)
    fi

    if [ -n "$serial_port" ] && [ -e "$serial_port" ]; then
        log "  开始监听开发板串口: $serial_port"
        if [[ "$PRINT_OUTPUT" == true ]]; then
            timeout "$wait_seconds" cat "$serial_port" 2>/dev/null | tee -a "$log_file" &
        else
            timeout "$wait_seconds" cat "$serial_port" 2>/dev/null >> "$log_file" &
        fi
        serial_pid=$!
    elif [ -n "$serial_port" ]; then
        log_warn "  开发板串口不存在: $serial_port"
    else
        log_warn "  未配置开发板串口输出: $board_name"
    fi

    control_board_power "$board_name" "on"

    while [ $remaining_time -gt 0 ]; do
        if grep -qE "Welcome to|test pass!|All tests passed!|simple_sleep passed!|Hello, world!|root@firefly:~#|root@phytium-Ubuntu:~#|Set hostname to|starry:~#|Last login:|Booting kernel with command" "$log_file" 2>/dev/null; then
            log "  检测到成功标识符!"
            success_detected=true
            break
        fi
        sleep 1
        ((remaining_time--))
    done

    if [ -n "$serial_pid" ]; then
        kill "$serial_pid" 2>/dev/null || true
        sleep 0.5
        pkill -9 -P "$serial_pid" 2>/dev/null || true
        kill -9 "$serial_pid" 2>/dev/null || true
    fi

    cleanup_board_resources "$board_name" "$test_dir"

    if [ "$success_detected" == true ]; then
        log_success "  检测到成功标识符，测试通过: $target_name"
        echo "passed" > "$status_file"
        return 0
    fi

    log_success "  仅上电等待测试完成: $target_name"
    echo "passed" > "$status_file"
    return 0
}
