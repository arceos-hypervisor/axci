#!/bin/bash
#
# config.sh - 配置加载、目标检测、依赖检查
#
# 此文件负责:
#   1. 从 rust-toolchain.toml 自动检测支持的架构
#   2. 检查运行所需的依赖工具
#   3. 加载测试配置文件 (.github/config.json 或 .test-config.json)
#   4. 设置输出目录结构
#
# 使用方式: source "$SCRIPT_DIR/lib/config.sh"
#

SCRIPT_DIR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_CONFIG/lib/common.sh"

# =============================================================================
# 架构检测函数
# =============================================================================

# 从 rust-toolchain.toml 中提取 targets 并映射到架构
# 返回: 空格分隔的架构列表 (如 "aarch64 x86_64")，或 "all"
detect_targets_from_toolchain() {
    local toolchain_file="$CTX_COMPONENT_DIR/rust-toolchain.toml"
    local detected_archs=()

    if [ ! -f "$toolchain_file" ]; then
        log_warn "未找到 rust-toolchain.toml，使用所有架构"
        echo "all"
        return
    fi

    # 提取 targets 数组
    local targets=$(grep -A 20 '^targets' "$toolchain_file" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)

    if [ -z "$targets" ]; then
        log_warn "rust-toolchain.toml 中未找到 targets，使用所有架构"
        echo "all"
        return
    fi

    log_debug "从 rust-toolchain.toml 检测到 targets:"

    # 解析每个 target 并映射到架构
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        log_debug "  - $target"

        case "$target" in
            *aarch64*)
                if [[ " ${detected_archs[*]} " != *" aarch64 "* ]]; then
                    detected_archs+=("aarch64")
                fi
                ;;
            *x86_64*)
                if [[ " ${detected_archs[*]} " != *" x86_64 "* ]]; then
                    detected_archs+=("x86_64")
                fi
                ;;
            *riscv64*)
                if [[ " ${detected_archs[*]} " != *" riscv64 "* ]]; then
                    detected_archs+=("riscv64")
                fi
                ;;
            *loongarch64*)
                if [[ " ${detected_archs[*]} " != *" loongarch64 "* ]]; then
                    detected_archs+=("loongarch64")
                fi
                ;;
        esac
    done <<< "$targets"

    if [ ${#detected_archs[@]} -eq 0 ]; then
        log_warn "无法从 targets 识别架构，使用所有架构"
        echo "all"
        return
    fi

    log "检测到的架构: ${detected_archs[*]}"
    echo "${detected_archs[*]}"
}

# =============================================================================
# 依赖检查函数
# =============================================================================

# 检查运行所需的依赖工具
# 必需: jq, git, cargo
# 可选: cargo-clone (如未安装会自动安装)
# 如缺少必需依赖则退出脚本
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

    # 检查并安装 cargo-clone
    if ! command -v cargo-clone &> /dev/null && ! cargo clone --help &> /dev/null; then
        log "安装 cargo-clone..."
        cargo install cargo-clone
    fi

    log_success "依赖检查通过"
}

# =============================================================================
# 默认测试目标配置
# 包含 QEMU 模拟测试和真实开发板测试的完整配置
# =============================================================================

# 默认测试目标 (JSON 格式)
# 每个目标包含: name, type(qemu/board), arch, repo, build, test, patch 等字段
CONST_DEFAULT_TEST_TARGETS='[
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
      "vmimage_name": "qemu_aarch64_arceos"
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
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-loongarch64",
    "type": "qemu",
    "arch": "loongarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-aarch64",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-x86_64",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-phytiumpi-arceos",
    "type": "board",
    "arch": "aarch64",
    "board": "phytiumpi",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/phytiumpi.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-e2000-smp1.toml",
      "vmimage_name": "phytiumpi_arceos,phytiumpi_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-phytiumpi-linux",
    "type": "board",
    "arch": "aarch64",
    "board": "phytiumpi",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/phytiumpi.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/linux-aarch64-e2000-smp1.toml",
      "vmimage_name": "phytiumpi_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-roc-rk3568-pc-arceos",
    "type": "board",
    "arch": "aarch64",
    "board": "roc-rk3568-pc",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/roc-rk3568-pc.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-rk3568-smp1.toml",
      "vmimage_name": "roc-rk3568-pc_arceos,roc-rk3568-pc_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-roc-rk3568-pc-linux",
    "type": "board",
    "arch": "aarch64",
    "board": "roc-rk3568-pc",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/roc-rk3568-pc.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/linux-aarch64-rk3568-smp1.toml",
      "vmimage_name": "roc-rk3568-pc_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  }
]'

# =============================================================================
# 配置加载函数
# =============================================================================

# 加载测试配置
# 1. 确定组件目录 (CTX_COMPONENT_DIR)
# 2. 查找配置文件 (优先级: --config > .github/config.json > .test-config.json)
# 3. 从 Cargo.toml 提取 crate 名称
# 4. 如无配置文件则使用 CONST_DEFAULT_TEST_TARGETS
# 设置共享上下文: CTX_CONFIG, CTX_COMPONENT_NAME, CTX_COMPONENT_CRATE
load_config() {
    # 确定组件目录
    if [ -z "$CTX_COMPONENT_DIR" ]; then
        CTX_COMPONENT_DIR="$(pwd)"
    fi

    # 尝试查找配置文件（可选）
    if [ -z "$CTX_CONFIG_FILE" ]; then
        if [ -f "$CTX_COMPONENT_DIR/.github/config.json" ]; then
            CTX_CONFIG_FILE="$CTX_COMPONENT_DIR/.github/config.json"
        elif [ -f "$CTX_COMPONENT_DIR/.test-config.json" ]; then
            CTX_CONFIG_FILE="$CTX_COMPONENT_DIR/.test-config.json"
        fi
    fi

    # 检测 crate 名称（从 Cargo.toml）
    if [ -f "$CTX_COMPONENT_DIR/Cargo.toml" ]; then
        CTX_COMPONENT_CRATE=$(grep '^name = ' "$CTX_COMPONENT_DIR/Cargo.toml" | head -1 | sed 's/name = "\(.*\)"/\1/' || basename "$CTX_COMPONENT_DIR")
    else
        CTX_COMPONENT_CRATE=$(basename "$CTX_COMPONENT_DIR")
    fi
    CTX_COMPONENT_NAME="$CTX_COMPONENT_CRATE"

    # 如果有配置文件，则使用配置文件
    if [ -n "$CTX_CONFIG_FILE" ] && [ -f "$CTX_CONFIG_FILE" ]; then
        log "加载配置: $CTX_CONFIG_FILE"
        CTX_CONFIG=$(cat "$CTX_CONFIG_FILE")
        # 从配置文件获取组件信息
        local config_name=$(echo "$CTX_CONFIG" | jq -r '.component.name // empty')
        local config_crate=$(echo "$CTX_CONFIG" | jq -r '.component.crate_name // empty')
        [ -n "$config_name" ] && CTX_COMPONENT_NAME="$config_name"
        [ -n "$config_crate" ] && CTX_COMPONENT_CRATE="$config_crate"

        # 检查配置文件是否包含 test_targets
        local has_targets=$(echo "$CTX_CONFIG" | jq 'has("test_targets")')
        if [ "$has_targets" != "true" ]; then
            log "配置文件不包含 test_targets，使用默认测试目标"
            local original_targets=$(echo "$CTX_CONFIG" | jq -c '{targets, unit_target_map}')
            CTX_CONFIG=$(echo "$original_targets" | jq -c '. + {"component":{"name":"'"$CTX_COMPONENT_NAME"'","crate_name":"'"$CTX_COMPONENT_CRATE"'"},"test_targets":'"$CONST_DEFAULT_TEST_TARGETS"'}')
        fi
    else
        log "未找到配置文件，使用默认测试目标"
        CTX_CONFIG="{\"component\":{\"name\":\"$CTX_COMPONENT_NAME\",\"crate_name\":\"$CTX_COMPONENT_CRATE\"},\"test_targets\":$CONST_DEFAULT_TEST_TARGETS}"
    fi

    log_debug "组件: $CTX_COMPONENT_NAME ($CTX_COMPONENT_CRATE)"
}

# =============================================================================
# 输出目录设置
# =============================================================================

# 设置测试结果输出目录
# 默认: $CTX_COMPONENT_DIR/test-results
# 创建 logs 子目录用于存储测试日志
# 设置共享上下文: CTX_OUTPUT_DIR
setup_output() {
    if [ -z "$CTX_OUTPUT_DIR" ]; then
        CTX_OUTPUT_DIR="$CTX_COMPONENT_DIR/test-results"
    fi

    sudo mkdir -p "$CTX_OUTPUT_DIR/logs"
    sudo chmod -R 777 "$CTX_OUTPUT_DIR"
    log_debug "输出目录: $CTX_OUTPUT_DIR"
}
