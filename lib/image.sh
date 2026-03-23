#!/bin/bash
#
# image.sh - 镜像下载和 ostool 安装（QEMU 和 Board 共用）
#
# 此文件负责:
#   1. 确保 ostool 工具已安装
#   2. 下载测试所需的虚拟机镜像 (kernel, rootfs 等)
#
# 镜像存储位置: /tmp/.axvisor-images/
#
# 使用方式: source "$SCRIPT_DIR/lib/image.sh"
#

SCRIPT_DIR_IMAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_IMAGE/lib/common.sh"

# =============================================================================
# 工具安装函数
# =============================================================================

# 确保 ostool 已安装
# ostool 用于管理操作系统镜像的下载和配置
ensure_ostool() {
    if ! command -v ostool &> /dev/null; then
        log "  安装 ostool..."
        cargo +stable install ostool --version ^0.8
    fi
}

# =============================================================================
# 镜像下载函数
# =============================================================================

# 下载测试镜像
# 参数:
#   $1 - vmconfigs: VM 配置文件列表 (逗号分隔)
#   $2 - vmimage_name: 镜像名称列表 (逗号分隔)
#   $3 - test_dir: 测试目录路径
#   $4 - log_file: 日志文件路径
#   $5 - status_file: 状态文件路径
# 返回: 0 成功, 1 失败
#
# 镜像保存到: /tmp/.axvisor-images/{image_name}/
# 如镜像已存在则跳过下载
download_images() {
    local vmconfigs=$1
    local vmimage_name=$2
    local test_dir=$3
    local log_file=$4
    local status_file=$5

    log "  下载测试镜像..."

    # 创建镜像目录
    local IMAGE_DIR="/tmp/.axvisor-images"
    sudo mkdir -p "$IMAGE_DIR"
    sudo chmod 777 "$IMAGE_DIR"

    # 检查并下载镜像
    IFS=',' read -ra CONFIGS <<< "$vmconfigs"
    IFS=',' read -ra IMAGES <<< "$vmimage_name"

    for i in "${!CONFIGS[@]}"; do
        img="${IMAGES[$i]}"
        img=$(echo "$img" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        config="${CONFIGS[$i]}"
        config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 检查镜像是否存在
        local img_path="${IMAGE_DIR}/${img}"
        if [ -d "$img_path" ]; then
            log "  镜像已存在: $img_path"
        else
            log "  镜像不存在，开始下载: $img"
            if [ -f "$test_dir/$config" ]; then
                cd "$test_dir"
                if cargo xtask image download $img >> "$log_file" 2>&1; then
                    log_success "  镜像下载成功: $img"
                else
                    log_error "  镜像下载失败: $img"
                    echo "failed" > "$status_file"
                    cd "$CTX_COMPONENT_DIR"
                    return 1
                fi
            else
                log_warn "  配置文件不存在: $config"
            fi
        fi
    done

    cd "$CTX_COMPONENT_DIR"
    return 0
}
