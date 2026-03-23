#!/usr/bin/env bash
#
# 组件代码质量检查脚本
#
# 此脚本用于检查 Rust 组件的代码质量，包括:
#   - cargo fmt: 代码格式检查
#   - cargo build: 编译检查
#   - cargo clippy: Lint 检查
#   - cargo doc: 文档构建检查
#
# 用法:
#   check.sh [选项] [crate|all]
#
# 示例:
#   check.sh axvcpu                                  # 检查单个组件
#   check.sh all                                     # 检查所有组件
#   check.sh --component-dir /path/to/crate          # 检查指定目录
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
CRATES_FILE="${SCRIPT_DIR}/crates.txt"
source "${SCRIPT_DIR}/lib/common.sh"

# =============================================================================
# 日志函数包装
# =============================================================================

die() { error "$*"; }
info() { log "$*"; }
success() { log_success "$*"; }
warn() { log_warn "$*"; }

# =============================================================================
# 配置变量
# =============================================================================

CHK_DEFAULT_TARGET="aarch64-unknown-none-softfloat"
CHK_RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links"
CHK_FILTER_TARGETS=""
CHK_CRATE_NAME=""
CHK_COMPONENT_DIR=""
CHK_ALL_FEATURES=true
CHK_SKIP_BUILD=false
CHK_LIST_TARGETS_JSON=false
CHK_ONLY_STAGE=""

# =============================================================================
# 辅助函数
# =============================================================================

# 显示使用帮助
usage() {
    cat << 'EOF'
组件代码质量检查脚本

用法:
  check.sh [选项] [crate|all]

参数:
  crate     组件名称，如 axvcpu、axaddrspace 等
  all       检查所有组件

选项:
  -c, --component-dir DIR    组件目录 (直接检查指定目录，无需 crate 名称)
  --targets TRIPLE[,TRIPLE,...]  编译目标三元组 (如: aarch64-unknown-none-softfloat)
                             优先级: CLI > config.json targets > 默认值
  --all-features             检查时附加 --all-features (默认)
  --no-all-features          检查时不附加 --all-features
  --skip-build               跳过 cargo build
  --list-targets-json        输出最终解析后的 targets JSON 数组
  --only STAGE              仅运行指定阶段: fmt|build|clippy|doc
  -h, --help                 显示此帮助

可用的目标架构:
  aarch64-unknown-none-softfloat  (默认)
  x86_64-unknown-none
  riscv64gc-unknown-none-elf

示例:
  check.sh axvcpu                                  # 使用默认目标
  check.sh axvcpu --targets x86_64-unknown-none   # 指定目标
  check.sh all                                     # 检查所有组件
  check.sh --component-dir /path/to/crate          # 直接检查指定目录
  check.sh -c /path/to/crate --targets aarch64-unknown-none-softfloat
EOF
}

# 从 crates.txt 读取所有组件名称
# 返回: 组件名称列表 (每行一个)
read_crates() {
    local crates=()
    while IFS= read -r crate || [[ -n "${crate}" ]]; do
        crate="${crate%$'\r'}"
        [[ -z "${crate}" ]] && continue
        crates+=("${crate}")
    done < "${CRATES_FILE}"
    printf '%s\n' "${crates[@]}"
}

# 解析命令行参数
# 设置全局变量: CHK_CRATE_NAME, CHK_COMPONENT_DIR, FILTER_TARGETS 等
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--component-dir)
                CHK_COMPONENT_DIR="$2"
                shift 2
                ;;
            --targets)
                CHK_FILTER_TARGETS="$2"
                shift 2
                ;;
            --all-features)
                CHK_ALL_FEATURES=true
                shift
                ;;
            --no-all-features)
                CHK_ALL_FEATURES=false
                shift
                ;;
            --skip-build)
                CHK_SKIP_BUILD=true
                shift
                ;;
            --list-targets-json)
                CHK_LIST_TARGETS_JSON=true
                shift
                ;;
            --only)
                CHK_ONLY_STAGE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            all)
                CHK_CRATE_NAME="all"
                shift
                ;;
            -*)
                die "未知选项: $1"
                ;;
            *)
                # 位置参数作为 crate 名称
                if [[ -z "${CHK_CRATE_NAME}" ]]; then
                    CHK_CRATE_NAME="$1"
                else
                    die "只能指定一个 crate 名称"
                fi
                shift
                ;;
        esac
    done
}

# 解析编译目标
# 优先级: CLI --targets > config.json targets > 默认值
# 返回: 逗号分隔的目标列表
resolve_targets() {
    local targets_input="$CHK_FILTER_TARGETS"
    local config_file=""

    # 确定配置文件路径
    if [[ -n "${CHK_COMPONENT_DIR}" ]]; then
        config_file="${CHK_COMPONENT_DIR}/.github/config.json"
    else
        config_file="${ROOT_DIR}/.github/config.json"
    fi

    # CLI 未指定，尝试 config.json 的 targets 字段
    if [[ -z "${targets_input}" ]] && [[ -f "${config_file}" ]]; then
        local config_targets=$(cat "${config_file}" | jq -r '.targets // [] | join(",")' 2>/dev/null)
        if [[ -n "${config_targets}" ]]; then
            targets_input="${config_targets}"
        fi
    fi

    # 仍为空，使用默认值
    if [[ -z "${targets_input}" ]]; then
        targets_input="${CHK_DEFAULT_TARGET}"
    fi

    # 返回解析后的目标列表
    echo "${targets_input}"
}

# 将逗号分隔的目标列表转换为 JSON 数组
# 参数: $1 - targets: 逗号分隔的目标列表
# 输出: JSON 数组到 stdout
targets_to_json() {
    local targets="$1"
    echo "${targets}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s -c
}

# 判断是否应该运行指定阶段
# 参数: $1 - stage: 阶段名称 (fmt/build/clippy/doc)
# 返回: 0 应运行, 1 应跳过
should_run_stage() {
    local stage="$1"
    [[ -z "${CHK_ONLY_STAGE}" || "${CHK_ONLY_STAGE}" == "${stage}" ]]
}

# =============================================================================
# 检查函数
# =============================================================================

# 检查代码格式 (cargo fmt --check)
# 参数:
#   $1 - crate: 组件名称
# 返回: 0 通过, 1 失败
check_fmt() {
    info "[$1] 检查代码格式"
    if cargo fmt --all -- --check >/dev/null 2>&1; then
        success "[$1] 代码格式检查通过"
    else
        warn "[$1] 代码格式检查失败，运行 'cargo fmt --all' 修复"; return 1
    fi
}

# 检查编译 (cargo build)
# 参数:
#   $1 - crate: 组件名称
#   $2 - target: 编译目标三元组
# 返回: 0 通过, 失败时退出脚本
check_build() {
    info "[$1] 构建检查 (target: $2)"
    local feature_args=()
    if [[ "${CHK_ALL_FEATURES}" == true ]]; then
        feature_args+=(--all-features)
    fi
    if cargo build --target "$2" "${feature_args[@]}" >/dev/null 2>&1; then
        success "[$1] 构建检查通过"
    else
        die "[$1] 构建检查失败"
    fi
}

# Clippy Lint 检查 (cargo clippy)
# 参数:
#   $1 - crate: 组件名称
#   $2 - target: 编译目标三元组
# 返回: 0 通过, 失败时退出脚本
check_clippy() {
    info "[$1] Clippy 检查"
    local feature_args=()
    if [[ "${CHK_ALL_FEATURES}" == true ]]; then
        feature_args+=(--all-features)
    fi
    if cargo clippy --target "$2" "${feature_args[@]}" -- -D warnings >/dev/null 2>&1; then
        success "[$1] Clippy 检查通过"
    else
        die "[$1] Clippy 检查失败"
    fi
}

# 文档构建检查 (cargo doc)
# 参数:
#   $1 - crate: 组件名称
#   $2 - target: 编译目标三元组
# 返回: 0 通过, 失败时退出脚本
check_doc() {
    info "[$1] 文档构建检查"
    local feature_args=()
    if [[ "${CHK_ALL_FEATURES}" == true ]]; then
        feature_args+=(--all-features)
    fi
    if RUSTDOCFLAGS="${CHK_RUSTDOCFLAGS}" cargo doc --no-deps --target "$2" "${feature_args[@]}" >/dev/null 2>&1; then
        success "[$1] 文档构建检查通过"
    else
        die "[$1] 文档构建检查失败"
    fi
}

# 检查单个组件的完整流程
# 参数:
#   $1 - crate: 组件名称
#   $2 - target: 编译目标三元组
# 返回: 0 通过, 1 失败
check_crate() {
    local crate="$1" target="$2" crate_dir="${ROOT_DIR}/${1}"
    
    [[ -d "${crate_dir}" ]] || die "组件 ${crate} 不存在"
    [[ -f "${crate_dir}/Cargo.toml" ]] || { warn "跳过 ${crate} (不是 Rust 项目)"; return 0; }
    
    printf '\n%b========== %s ==========%b\n' "${BLUE}" "${crate}" "${NC}"
    
    pushd "${crate_dir}" >/dev/null
    if should_run_stage fmt; then
        check_fmt "${crate}" || { popd >/dev/null; return 1; }
    fi
    if should_run_stage build && [[ "${CHK_SKIP_BUILD}" != true ]]; then
        check_build "${crate}" "${target}"
    fi
    if should_run_stage clippy; then
        check_clippy "${crate}" "${target}"
    fi
    if should_run_stage doc; then
        check_doc "${crate}" "${target}"
    fi
    popd >/dev/null
    
    success "[${crate}] 所有检查通过"
}

# 检查指定目录的组件 (通过 --component-dir 指定)
# 参数:
#   $1 - target: 编译目标三元组
# 返回: 0 通过, 1 失败
check_component_dir() {
    local target="$1"
    local crate_name=$(basename "${CHK_COMPONENT_DIR}")
    
    [[ -d "${CHK_COMPONENT_DIR}" ]] || die "组件目录不存在: ${CHK_COMPONENT_DIR}"
    [[ -f "${CHK_COMPONENT_DIR}/Cargo.toml" ]] || die "不是 Rust 项目: ${CHK_COMPONENT_DIR}"
    
    printf '\n%b========== %s ==========%b\n' "${BLUE}" "${crate_name}" "${NC}"
    
    pushd "${CHK_COMPONENT_DIR}" >/dev/null
    if should_run_stage fmt; then
        check_fmt "${crate_name}" || { popd >/dev/null; return 1; }
    fi
    if should_run_stage build && [[ "${CHK_SKIP_BUILD}" != true ]]; then
        check_build "${crate_name}" "${target}"
    fi
    if should_run_stage clippy; then
        check_clippy "${crate_name}" "${target}"
    fi
    if should_run_stage doc; then
        check_doc "${crate_name}" "${target}"
    fi
    popd >/dev/null
    
    success "[${crate_name}] 所有检查通过"
}

# 检查所有组件 (读取 crates.txt)
# 参数:
#   $1 - target: 编译目标三元组
# 返回: 0 全部通过, 有失败时退出脚本
check_all() {
    local target="$1"
    local crates passed=() failed=()
    mapfile -t crates < <(read_crates)
    
    info "检查所有组件 (${#crates[@]} 个)..."
    
    for crate in "${crates[@]}"; do
        # 使用子 shell 隔离错误，确保一个组件失败不影响其他组件
        if (check_crate "${crate}" "${target}"); then
            passed+=("${crate}")
        else
            failed+=("${crate}")
        fi
    done
    
    printf '\n%b========================================%b\n' "${BLUE}" "${NC}"
    printf '%b           检查结果汇总%b\n' "${BLUE}" "${NC}"
    printf '%b========================================%b\n\n' "${BLUE}" "${NC}"

    if [[ ${#passed[@]} -gt 0 ]]; then
        success "通过 ${#passed[@]} 个:"
        for crate in "${passed[@]}"; do
            printf '  %b✓%b %s\n' "${GREEN}" "${NC}" "${crate}"
        done
        printf '\n'
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        printf '%b失败 %d 个:%b\n' "${RED}" "${#failed[@]}" "${NC}"
        for crate in "${failed[@]}"; do
            printf '  %b✗%b %s\n' "${RED}" "${NC}" "${crate}"
        done
        printf '\n'
        die "检查完成，共 ${#failed[@]} 个组件失败"
    else
        success "所有 ${#passed[@]} 个组件检查通过"
    fi
}

# =============================================================================
# 主函数
# =============================================================================

# 主入口函数
# 解析参数并执行检查流程
main() {
    parse_args "$@"
    
    local resolved_targets
    resolved_targets="$(resolve_targets)"

    if [[ "${CHK_LIST_TARGETS_JSON}" == true ]]; then
        targets_to_json "${resolved_targets}"
        exit 0
    fi
    
    # 如果指定了 --component-dir，直接检查该目录
    if [[ -n "${CHK_COMPONENT_DIR}" ]]; then
        local targets_array=()
        IFS=',' read -ra targets_array <<< "${resolved_targets}"
        
        info "组件目录: ${CHK_COMPONENT_DIR}"
        info "检查目标: ${targets_array[*]}"
        
        # 为每个目标运行检查
        local all_passed=true
        for target in "${targets_array[@]}"; do
            target=$(echo "$target" | xargs) # trim
            [[ -z "${target}" ]] && continue
            
            printf '\n%b========== 目标: %s ==========%b\n' "${BLUE}" "${target}" "${NC}"
            
            if ! check_component_dir "${target}"; then
                all_passed=false
            fi
        done
        
        if [[ "${all_passed}" == true ]]; then
            success "所有检查通过!"
            exit 0
        else
            die "部分检查失败"
        fi
        return
    fi
    
    # 如果没有指定 crate，显示帮助
    if [[ -z "${CHK_CRATE_NAME}" ]]; then
        usage
        exit 0
    fi
    
    local targets_array=()
    IFS=',' read -ra targets_array <<< "${resolved_targets}"
    
    info "检查目标: ${targets_array[*]}"
    cd "${ROOT_DIR}"
    
    # 为每个目标运行检查
    local all_passed=true
    for target in "${targets_array[@]}"; do
        target=$(echo "$target" | xargs) # trim
        [[ -z "${target}" ]] && continue
        
        printf '\n%b========== 目标: %s ==========%b\n' "${BLUE}" "${target}" "${NC}"
        
        if [[ "${CHK_CRATE_NAME}" == "all" ]]; then
            if ! check_all "${target}"; then
                all_passed=false
            fi
        else
            if ! check_crate "${CHK_CRATE_NAME}" "${target}"; then
                all_passed=false
            fi
        fi
    done
    
    if [[ "${all_passed}" == true ]]; then
        success "所有检查通过!"
        exit 0
    else
        die "部分检查失败"
    fi
}

main "$@"
