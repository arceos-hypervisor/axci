#!/bin/bash
#
# Hypervisor Test Framework - 本地测试脚本
# 此脚本可独立运行，也可被各组件调用
#
# 用法:
#   ./tests.sh                           # 运行所有测试
#   ./tests.sh --target axvisor          # 仅测试指定目标
#   ./tests.sh --config /path/to/.test-config.json
#   ./tests.sh --component-dir /path/to/component
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$SCRIPT_DIR"
COMPONENT_DIR=""
CONFIG_FILE=""
TEST_TARGET="all"
VERBOSE=false
CLEANUP=true
DRY_RUN=false
PARALLEL=true
OUTPUT_DIR=""

# 帮助信息
show_help() {
    cat << 'EOF'
Hypervisor Test Framework - 本地测试脚本

用法:
  tests.sh [选项]

选项:
  -c, --component-dir DIR    组件目录 (默认: 当前目录)
  -f, --config FILE          配置文件路径 (可选，默认使用内置测试目标)
  -t, --target TARGET        测试目标: all, axvisor-qemu, starry, 或具体目标名 (默认: all)
  -o, --output DIR           输出目录 (默认: COMPONENT_DIR/test-results)
  -v, --verbose              详细输出
  --no-cleanup               不清理临时文件
  --dry-run                  仅显示将要执行的命令
  --sequential               顺序执行测试 (不并行)
  -h, --help                 显示此帮助

测试目标:
  all                        运行所有测试
  axvisor-qemu               运行所有 axvisor QEMU 测试
  starry                     运行所有 starry 测试
  axvisor-qemu-aarch64-arceos     测试 axvisor 在 QEMU aarch64 上的 ArceOS 镜像
  axvisor-qemu-aarch64-linux      测试 axvisor 在 QEMU aarch64 上的 Linux 镜像
  axvisor-qemu-x86_64-nimbos      测试 axvisor 在 QEMU x86_64 上的 NimbOS 镜像
  starry-riscv64             测试 starry 在 riscv64 架构下
  starry-loongarch64         测试 starry 在 loongarch64 架构下
  starry-aarch64             测试 starry 在 aarch64 架构下
  starry-x86_64              测试 starry 在 x86_64 架构下

镜像下载:
  镜像将从 https://github.com/arceos-hypervisor/axvisor-guest/releases/v0.0.22 自动下载
  存储位置: /tmp/.axvisor-images

示例:
  tests.sh                                    # 在当前目录运行所有测试
  tests.sh -t axvisor-qemu                    # 仅运行 axvisor QEMU 测试
  tests.sh -t starry-aarch64                  # 仅运行 starry aarch64 测试
  tests.sh --dry-run -v                       # 显示将要执行的命令

EOF
}

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--component-dir)
                COMPONENT_DIR="$2"
                shift 2
                ;;
            -f|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--target)
                TEST_TARGET="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --sequential)
                PARALLEL=false
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 日志函数
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { 
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

error() { log_error "$1"; exit 1; }

# 检查依赖
check_dependencies() {
    log "检查依赖..."
    
    local missing=()
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    # 检查 git
    if ! command -v git &> /dev/null; then
        missing+=("git")
    fi
    
    # 检查 cargo
    if ! command -v cargo &> /dev/null; then
        missing+=("cargo (Rust)")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少依赖: ${missing[*]}\n请安装后重试。"
    fi
    
    log_success "依赖检查通过"
}

# 默认测试目标（与 .github/workflows/test.yml 保持一致）
DEFAULT_TARGETS='[
  {
    "name": "axvisor-qemu-aarch64-arceos",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-aarch64.toml",
      "qemu_config": ".github/workflows/qemu-aarch64.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-qemu-smp1.toml",
      "vmimage_name": "qemu_aarch64_arceos,qemu_aarch64_arceos"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-qemu-aarch64-linux",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-aarch64.toml",
      "qemu_config": ".github/workflows/qemu-aarch64.toml",
      "vmconfigs": "configs/vms/linux-aarch64-qemu-smp1.toml",
      "vmimage_name": "qemu_aarch64_linux"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-qemu-x86_64-nimbos",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-x86_64.toml",
      "qemu_config": ".github/workflows/qemu-x86_64.toml",
      "vmconfigs": "configs/vms/nimbos-x86_64-qemu-smp1.toml",
      "vmimage_name": "qemu_x86_64_nimbos"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-riscv64",
    "type": "qemu",
    "arch": "riscv64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {
      "command": "scripts/ci-test.py"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-loongarch64",
    "type": "qemu",
    "arch": "loongarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {
      "command": "scripts/ci-test.py"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-aarch64",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {
      "command": "scripts/ci-test.py"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-x86_64",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {
      "command": "scripts/ci-test.py"
    },
    "patch": {"path_template": "../component"}
  }
]'

# 加载配置
load_config() {
    # 确定组件目录
    if [ -z "$COMPONENT_DIR" ]; then
        COMPONENT_DIR="$(pwd)"
    fi
    
    # 尝试查找配置文件（可选）
    if [ -z "$CONFIG_FILE" ]; then
        if [ -f "$COMPONENT_DIR/.github/config.json" ]; then
            CONFIG_FILE="$COMPONENT_DIR/.github/config.json"
        elif [ -f "$COMPONENT_DIR/.test-config.json" ]; then
            CONFIG_FILE="$COMPONENT_DIR/.test-config.json"
        fi
    fi
    
    # 检测 crate 名称（从 Cargo.toml）
    if [ -f "$COMPONENT_DIR/Cargo.toml" ]; then
        COMPONENT_CRATE=$(grep '^name = ' "$COMPONENT_DIR/Cargo.toml" | head -1 | sed 's/name = "\(.*\)"/\1/' || basename "$COMPONENT_DIR")
    else
        COMPONENT_CRATE=$(basename "$COMPONENT_DIR")
    fi
    COMPONENT_NAME="$COMPONENT_CRATE"
    
    # 如果有配置文件，则使用配置文件
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log "加载配置: $CONFIG_FILE"
        CONFIG=$(cat "$CONFIG_FILE")
        # 从配置文件获取组件信息
        local config_name=$(echo "$CONFIG" | jq -r '.component.name // empty')
        local config_crate=$(echo "$CONFIG" | jq -r '.component.crate_name // empty')
        [ -n "$config_name" ] && COMPONENT_NAME="$config_name"
        [ -n "$config_crate" ] && COMPONENT_CRATE="$config_crate"
        
        # 检查配置文件是否包含 test_targets
        local has_targets=$(echo "$CONFIG" | jq 'has("test_targets")')
        if [ "$has_targets" != "true" ]; then
            log "配置文件不包含 test_targets，使用默认测试目标"
            CONFIG="{\"component\":{\"name\":\"$COMPONENT_NAME\",\"crate_name\":\"$COMPONENT_CRATE\"},\"test_targets\":$DEFAULT_TARGETS}"
        fi
    else
        log "未找到配置文件，使用默认测试目标"
        CONFIG="{\"component\":{\"name\":\"$COMPONENT_NAME\",\"crate_name\":\"$COMPONENT_CRATE\"},\"test_targets\":$DEFAULT_TARGETS}"
    fi
    
    log_debug "组件: $COMPONENT_NAME ($COMPONENT_CRATE)"
}

# 设置输出目录
setup_output() {
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$COMPONENT_DIR/test-results"
    fi
    
    mkdir -p "$OUTPUT_DIR/logs"
    log_debug "输出目录: $OUTPUT_DIR"
}

# 获取要测试的目标
get_test_targets() {
    local targets=()
    
    if [ "$TEST_TARGET" == "all" ]; then
        # 从配置获取所有目标
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            targets+=("$(echo "$CONFIG" | jq -r ".test_targets[$i].name")")
        done
    elif [[ "$TEST_TARGET" == axvisor-qemu ]]; then
        # 运行所有 axvisor QEMU 测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == axvisor-qemu-* ]]; then
                targets+=("$name")
            fi
        done
    elif [[ "$TEST_TARGET" == axvisor-board ]]; then
        # 运行所有 axvisor 开发板测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == axvisor-board-* ]]; then
                targets+=("$name")
            fi
        done
    elif [[ "$TEST_TARGET" == starry ]]; then
        # 运行所有 starry 测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == starry-* ]]; then
                targets+=("$name")
            fi
        done
    else
        # 具体目标名称
        targets+=("$TEST_TARGET")
    fi
    
    echo "${targets[@]}"
}

# 运行单个测试目标
run_test_target() {
    local target_name=$1
    local log_file="$OUTPUT_DIR/logs/${target_name}_$(date +%Y%m%d_%H%M%S).log"
    local status_file="$OUTPUT_DIR/${target_name}.status"
    
    log "测试目标: $target_name"
    
    # 获取目标配置
    local target_config=$(echo "$CONFIG" | jq -e ".test_targets[] | select(.name == \"$target_name\")")
    if [ -z "$target_config" ]; then
        log_error "未找到测试目标配置: $target_name"
        echo "failed" > "$status_file"
        return 1
    fi
    
    local repo_url=$(echo "$target_config" | jq -r '.repo.url')
    local repo_branch=$(echo "$target_config" | jq -r '.repo.branch // "main"')
    local test_type=$(echo "$target_config" | jq -r '.type // "qemu"')
    local build_cmd=$(echo "$target_config" | jq -r '.build.command')
    local timeout_min=$(echo "$target_config" | jq -r '.build.timeout_minutes // 15')
    
    log_debug "  仓库: $repo_url ($repo_branch)"
    log_debug "  类型: $test_type"
    log_debug "  构建: $build_cmd"
    log_debug "  超时: ${timeout_min}分钟"
    
    # 测试目录
    local test_dir="$OUTPUT_DIR/repos/$target_name"
    
    # 克隆或更新仓库
    if [ ! -d "$test_dir" ]; then
        log "  克隆仓库..."
        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] git clone --depth 1 -b $repo_branch $repo_url $test_dir"
        else
            if ! git clone --depth 1 -b $repo_branch "$repo_url" "$test_dir" >> "$log_file" 2>&1; then
                log_error "  克隆仓库失败: $repo_url"
                echo "failed" > "$status_file"
                return 1
            fi
            # 初始化子模块
            if [ -f "$test_dir/.gitmodules" ]; then
                log "  初始化子模块..."
                (cd "$test_dir" && git submodule update --init --recursive) >> "$log_file" 2>&1 || true
            fi
        fi
    else
        log "  更新仓库..."
        if [ "$DRY_RUN" != true ]; then
            (cd "$test_dir" && git pull) >> "$log_file" 2>&1 || true
        fi
    fi
    
    # 确保仓库目录存在 (dry-run 模式下跳过)
    if [ "$DRY_RUN" != true ] && [ ! -d "$test_dir" ]; then
        log_error "  仓库目录不存在: $test_dir"
        echo "failed" > "$status_file"
        return 1
    fi
    
    # dry-run 模式下跳过后续操作
    if [ "$DRY_RUN" == true ]; then
        log "  DRY RUN: 跳过 patch、构建和测试"
        echo "skipped" > "$status_file"
        return 2
    fi
    
    # 应用 patch - 与 CI 逻辑保持一致
    # 优先级: 目标配置 > 全局配置 > 默认值
    local patch_section=$(echo "$target_config" | jq -r '.patch.section // empty')
    [ -z "$patch_section" ] && patch_section=$(echo "$CONFIG" | jq -r '.patch.section // "crates-io"')
    
    local patch_path=$(echo "$target_config" | jq -r '.patch.path_template // empty')
    [ -z "$patch_path" ] && patch_path=$(echo "$CONFIG" | jq -r '.patch.path_template // "../component"')
    
    # 转换为绝对路径
    if [[ "$patch_path" == ".."* ]]; then
        # 尝试从 test_dir 解析相对路径
        local resolved_path="$test_dir/$patch_path"
        if [ -d "$resolved_path" ]; then
            patch_path="$(cd "$resolved_path" && pwd)"
        else
            # 如果相对路径解析失败，直接使用组件目录的绝对路径
            log "  相对路径 $patch_path 不存在，使用组件目录: $COMPONENT_DIR"
            patch_path="$COMPONENT_DIR"
        fi
    fi
    
    log "  应用组件 patch (section: $patch_section, path: $patch_path)..."
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] 添加 patch 到 $test_dir/Cargo.toml"
    else
        cd "$test_dir"
        
        # 检查是否已添加该组件的 patch（只在 [patch.*] section 中检查）
        # 使用 awk 提取所有 [patch.*] section 的内容并检查
        local already_patched=$(awk '/^\[patch\./,/^\[/ {print}' Cargo.toml 2>/dev/null | grep -q "^$COMPONENT_CRATE\s*=" && echo "yes" || echo "no")
        if [ "$already_patched" == "yes" ]; then
            log "  组件 $COMPONENT_CRATE 已在 patch 中"
        else
            # 检查是否已存在 [patch.$patch_section] section
            if grep -q "^\[patch\.$patch_section\]" Cargo.toml 2>/dev/null; then
                # 在现有的 section 后添加
                # 使用 sed 在匹配行后插入
                sed -i "/^\[patch\.$patch_section\]/a $COMPONENT_CRATE = { path = \"$patch_path\" }" Cargo.toml
                log_debug "已在现有 patch section 中添加组件"
            else
                # 创建新的 section
                cat >> Cargo.toml << EOF

[patch.$patch_section]
$COMPONENT_CRATE = { path = "$patch_path" }
EOF
                log_debug "已创建新的 patch section 并添加组件"
            fi
        fi
    fi
    
    # 执行构建
    if [ -n "$build_cmd" ]; then
        log "  构建... ($build_cmd, timeout: ${timeout_min}m)"
        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] cd $test_dir && timeout ${timeout_min}m $build_cmd"
        else
            cd "$test_dir"
            if timeout "${timeout_min}m" sh -c "$build_cmd" >> "$log_file" 2>&1; then
                log_success "  构建成功: $target_name"
            else
                local exit_code=$?
                if [ $exit_code -eq 124 ]; then
                    log_error "  构建超时: $target_name"
                else
                    log_error "  构建失败: $target_name (退出码: $exit_code)"
                fi
                echo "failed" > "$status_file"
                cd "$COMPONENT_DIR"
                return 1
            fi
        fi
    fi
    
    # 执行测试（如果有测试配置）
    local has_test=$(echo "$target_config" | jq 'has("test")')
    if [ "$has_test" == "true" ]; then
        local test_cmd=$(echo "$target_config" | jq -r '.test.command')
        local test_timeout=$(echo "$target_config" | jq -r '.test.timeout_minutes // 30')
        
        log "  运行测试... ($test_cmd, timeout: ${test_timeout}m)"
        
        # 检查是否为开发板测试
        if [ "$test_type" == "board" ]; then
            local board_name=$(echo "$target_config" | jq -r '.board')
            log_warn "  开发板测试需要真实硬件: $board_name"
            log_warn "  跳过开发板测试（本地环境无硬件）"
            echo "skipped" > "$status_file"
            cd "$COMPONENT_DIR"
            return 2  # 返回 2 表示跳过
        fi
        
        # 下载镜像和配置（仅适用于 axvisor QEMU 测试）
        if [[ "$target_name" == axvisor-qemu-* ]]; then
            local arch=$(echo "$target_config" | jq -r '.arch')
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            local vmimage_name=$(echo "$target_config" | jq -r '.test.vmimage_name // empty')
            
            if [ -n "$vmimage_name" ]; then
                log "  下载测试镜像..."
                
                # 创建镜像目录
                local IMAGE_DIR="/tmp/.axvisor-images"
                mkdir -p "$IMAGE_DIR"
                
                # 安装 ostool（如果尚未安装）
                if ! command -v ostool &> /dev/null; then
                    log "  安装 ostool..."
                    cargo +stable install ostool --version ^0.8
                fi
                
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
                                cd "$COMPONENT_DIR"
                                return 1
                            fi
                        else
                            log_warn "  配置文件不存在: $config"
                        fi
                    fi
                    
                    if [ -f "$test_dir/$config" ]; then
                        cd "$test_dir"
                        
                        # 获取 image_location
                        local image_location=$(sed -n 's/^image_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config")
                        local img_name="qemu-$arch"
                        
                        case "$image_location" in
                        "fs")
                            log "  文件系统存储模式 - 无需更新配置"
                            ;;
                        "memory")
                            sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$img_name"'"|' "$config"
                            log "  内存存储模式 - 已更新 kernel_path"
                            ;;
                        *)
                            log "  未知的 image_location: $image_location"
                            ;;
                        esac
                        
                        # 检查并处理 rootfs.img
                        local ROOTFS_IMG_PATH="${IMAGE_DIR}/$img/rootfs.img"
                        local qemu_config="$test_dir/$(echo "$target_config" | jq -r '.test.qemu_config')"
                        
                        if [ -f "${ROOTFS_IMG_PATH}" ]; then
                            log "  找到 rootfs.img，更新 $qemu_config"
                            sed -i 's|file=${workspaceFolder}/tmp/rootfs.img|file='"${ROOTFS_IMG_PATH}"'|' "$qemu_config"
                            log "  Rootfs 配置完成"
                        else
                            log "  未找到 rootfs.img，移除 rootfs 设备配置"
                            sed -i '/-device/,/virtio-blk-device,drive=disk0/d' "$qemu_config"
                            sed -i '/-drive/,/id=disk0,if=none,format=raw,file=${workspaceFolder}\/tmp\/rootfs.img/d' "$qemu_config"
                            sed -i 's/root=\/dev\/vda rw //' "$qemu_config"
                            log "  Rootfs 设备配置已移除"
                        fi
                    else
                        log_warn "  配置文件不存在: $config"
                    fi
                done
                cd "$COMPONENT_DIR"
            fi
        fi
        
        # 准备测试命令
        local full_test_cmd=""
        if [[ "$target_name" == axvisor-* ]]; then
            # Axvisor QEMU 测试
            local build_config=$(echo "$target_config" | jq -r '.test.build_config')
            local qemu_config=$(echo "$target_config" | jq -r '.test.qemu_config')
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            full_test_cmd="$test_cmd --build-config $build_config --qemu-config $qemu_config --vmconfigs $vmconfigs"
        elif [[ "$target_name" == starry-* ]]; then
            # Starry 测试
            local arch=$(echo "$target_config" | jq -r '.arch')
            full_test_cmd="ARCH=$arch $test_cmd $arch"
        fi
        
        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] cd $test_dir && timeout ${test_timeout}m $full_test_cmd"
        else
            cd "$test_dir"
            export RUST_LOG=debug
            if timeout "${test_timeout}m" sh -c "$full_test_cmd" >> "$log_file" 2>&1; then
                log_success "  测试成功: $target_name"
                echo "passed" > "$status_file"
                cd "$COMPONENT_DIR"
                return 0
            else
                local exit_code=$?
                if [ $exit_code -eq 124 ]; then
                    log_error "  测试超时: $target_name"
                else
                    log_error "  测试失败: $target_name (退出码: $exit_code)"
                fi
                echo "failed" > "$status_file"
                cd "$COMPONENT_DIR"
                return 1
            fi
        fi
    else
        # 没有测试配置，仅构建成功就算通过
        log_success "  仅构建，无测试: $target_name"
        echo "passed" > "$status_file"
        cd "$COMPONENT_DIR"
        return 0
    fi
}

# 运行所有测试
run_all_tests() {
    local targets=$(get_test_targets)
    local failed=0
    local passed=0
    local skipped=0
    local pids=()
    local target_array=()
    
    # 转换为数组
    read -ra target_array <<< "$targets"
    
    log "测试目标: ${target_array[*]}"
    echo ""
    
    if [ "$PARALLEL" == true ] && [ ${#target_array[@]} -gt 1 ]; then
        # 并行执行
        for target in "${target_array[@]}"; do
            run_test_target "$target" &
            pids+=($!)
        done
        
        # 等待所有任务完成
        for i in "${!pids[@]}"; do
            if ! wait ${pids[$i]}; then
                ((failed++))
            else
                ((passed++))
            fi
        done
    else
        # 顺序执行
        for target in "${target_array[@]}"; do
            run_test_target "$target"
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                ((passed++))
            elif [ $exit_code -eq 2 ]; then
                ((skipped++))
            else
                ((failed++))
            fi
        done
    fi
    
    echo ""
    log "测试结果:"
    echo "  - 通过: $passed"
    echo "  - 失败: $failed"
    echo "  - 跳过: $skipped"
    
    # 生成报告
    generate_report "$passed" "$failed" "$skipped"
    
    if [ $failed -gt 0 ]; then
        return 1
    fi
    return 0
}

# 生成报告
generate_report() {
    local passed=$1
    local failed=$2
    local skipped=$3
    local report_file="$OUTPUT_DIR/report.md"
    
    cat > "$report_file" << EOF
# 测试报告

**组件**: $COMPONENT_NAME 
**时间**: $(date '+%Y-%m-%d %H:%M:%S')  
**配置**: $CONFIG_FILE

## 结果汇总

| 状态 | 数量 |
|------|------|
| ✅ 通过 | $passed |
| ❌ 失败 | $failed |
| ⏭️ 跳过 | $skipped |

## 详细结果

EOF
    
    for status_file in "$OUTPUT_DIR"/*.status; do
        if [ -f "$status_file" ]; then
            local name=$(basename "$status_file" .status)
            local status=$(cat "$status_file")
            if [ "$status" == "passed" ]; then
                echo "- $name: ✅ 通过" >> "$report_file"
            elif [ "$status" == "skipped" ]; then
                echo "- $name: ⏭️ 跳过 (需要硬件)" >> "$report_file"
            else
                echo "- $name: ❌ 失败" >> "$report_file"
            fi
        fi
    done
    
    log_debug "报告已生成: $report_file"
}

# 清理
cleanup() {
    if [ "$CLEANUP" == true ] && [ "$DRY_RUN" != true ]; then
        log_debug "清理临时文件..."
        
        # 恢复 Cargo.toml
        for test_dir in "$OUTPUT_DIR/repos"/*; do
            if [ -d "$test_dir" ]; then
                (cd "$test_dir" && git checkout Cargo.toml 2>/dev/null) || true
            fi
        done
    fi
}

# 主函数
main() {
    parse_args "$@"
    
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Hypervisor Test Framework${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    
    check_dependencies
    load_config
    
    log "配置加载完成"
    log "组件: $COMPONENT_NAME ($COMPONENT_CRATE)"
    
    setup_output
    
    log "输出目录: $OUTPUT_DIR"
    
    if [ "$DRY_RUN" == true ]; then
        log_warn "DRY RUN 模式 - 不会执行实际操作"
    fi
    
    # 临时禁用 set -e 以捕获 run_all_tests 的返回值
    set +e
    run_all_tests
    local result=$?
    set -e
    
    cleanup
    
    echo ""
    if [ $result -eq 0 ]; then
        log_success "所有测试通过!"
    elif [ $result -eq 2 ]; then
        log_warn "部分测试被跳过（需要硬件）"
    else
        log_error "部分测试失败"
    fi
    
    exit $result
}

# 捕获信号
trap cleanup EXIT INT TERM

main "$@"
