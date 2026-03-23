#!/usr/bin/env bash
#
# Hypervisor Test Framework - 本地测试脚本
# 此脚本可独立运行，也可被各组件调用
#
# 用法:
#   ./tests.sh                           # 运行所有测试
#   ./tests.sh --suite axvisor-qemu      # 仅测试指定套件
#   ./tests.sh --config /path/to/.test-config.json
#   ./tests.sh --component-dir /path/to/component
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
FRAMEWORK_DIR="$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/repo.sh"
source "$SCRIPT_DIR/lib/patch.sh"
source "$SCRIPT_DIR/lib/image.sh"
source "$SCRIPT_DIR/lib/qemu.sh"
source "$SCRIPT_DIR/lib/board.sh"
source "$SCRIPT_DIR/lib/runner.sh"
source "$SCRIPT_DIR/lib/report.sh"
source "$SCRIPT_DIR/lib/test_flow.sh"

CTX_COMPONENT_DIR=""
CTX_CONFIG_FILE=""
CTX_OUTPUT_DIR=""
CTX_CONFIG=""
CTX_COMPONENT_NAME=""
CTX_COMPONENT_CRATE=""
CTX_UNIT_TEST_TRIPLES=""
CTX_RESOLVED_TRIPLES=""
CTX_RESOLVED_ARCHS=""

ARG_TEST_MODE="all"
ARG_FILTER_TARGETS=""
ARG_FILTER_SUITE=""
ARG_GIT_BRANCH=""

OPT_VERBOSE=false
OPT_CLEANUP=true
OPT_DRY_RUN=false
OPT_PARALLEL=false
OPT_USE_GIT=false
OPT_CLEAN_RESULTS=false
OPT_LIST_JSON=false
OPT_LIST_AUTO=false
OPT_USE_FS_MODE=false
OPT_PRINT_OUTPUT=false

show_help() {
    cat <<'EOF'
Hypervisor Test Framework - 本地测试脚本

用法:
  tests.sh [选项] [all|unit|integration|list]

选项:
  -c, --component-dir DIR         组件目录 (默认: 当前目录)
  -f, --config FILE               配置文件路径 (可选，默认使用内置测试目标)
  --targets TRIPLE[,TRIPLE,...]   编译目标三元组 (如: aarch64-unknown-none-softfloat)
                                  用于集成测试架构过滤，支持前缀匹配
                                  优先级: CLI > config.json targets > rust-toolchain.toml 自动检测
  -s, --suite NAME[,NAME,...]     测试套件过滤 (如: axvisor-qemu,starry-aarch64)
                                  支持精确名称和前缀匹配 (axvisor-qemu 匹配 axvisor-qemu-*)
                                  优先级: CLI > config.json test_targets > 全部
  -o, --output DIR                输出目录 (默认: 当前组件目录/test-results)
  -v, --verbose                   详细输出
  --no-cleanup                    不清理临时文件
  --dry-run                       仅显示将要执行的命令
  --parallel                      并行执行测试 (默认顺序执行)
  --from-git                      从 git 仓库拉取代码 (默认从 crates.io 下载)
  --branch BRANCH                 指定 git 分支 (仅与 --from-git 一起使用)
  --clean                         清理测试生成的 test-results 目录
  --list-json                     列出所有测试目标 (JSON 格式，用于 CI matrix)
  --list-auto                     列出自动检测的测试目标 (JSON 格式)
  --fs                            使用文件系统模式，不修改配置文件
  --print                         打印 U-Boot 和串口输出到命令行
  -h, --help                      显示此帮助

测试模式:
  all                             运行单元测试 + 集成测试 (默认)
  unit                            运行单元测试
  integration                     运行集成测试
  list                            列出所有可用测试用例

示例:
  tests.sh
  tests.sh unit
  tests.sh integration --targets aarch64-unknown-none-softfloat
  tests.sh integration --suite axvisor-qemu
  tests.sh --dry-run -v
EOF
}

require_arg() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "$value" || "$value" == -* ]]; then
        error "选项 $option 需要参数"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            all|unit|integration|list)
                ARG_TEST_MODE="$1"
                shift
                ;;
            -c|--component-dir)
                require_arg "$1" "${2:-}"
                CTX_COMPONENT_DIR="$2"
                shift 2
                ;;
            -f|--config)
                require_arg "$1" "${2:-}"
                CTX_CONFIG_FILE="$2"
                shift 2
                ;;
            --targets)
                require_arg "$1" "${2:-}"
                ARG_FILTER_TARGETS="$2"
                shift 2
                ;;
            -s|--suite)
                require_arg "$1" "${2:-}"
                ARG_FILTER_SUITE="$2"
                shift 2
                ;;
            -o|--output)
                require_arg "$1" "${2:-}"
                CTX_OUTPUT_DIR="$2"
                shift 2
                ;;
            -v|--verbose)
                OPT_VERBOSE=true
                shift
                ;;
            --no-cleanup)
                OPT_CLEANUP=false
                shift
                ;;
            --dry-run)
                OPT_DRY_RUN=true
                shift
                ;;
            --parallel)
                OPT_PARALLEL=true
                shift
                ;;
            --from-git)
                OPT_USE_GIT=true
                shift
                ;;
            --branch)
                require_arg "$1" "${2:-}"
                ARG_GIT_BRANCH="$2"
                shift 2
                ;;
            --clean)
                OPT_CLEAN_RESULTS=true
                shift
                ;;
            --list-json)
                OPT_LIST_JSON=true
                shift
                ;;
            --list-auto)
                OPT_LIST_AUTO=true
                shift
                ;;
            --fs)
                OPT_USE_FS_MODE=true
                shift
                ;;
            --print)
                OPT_PRINT_OUTPUT=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知选项: $1"
                ;;
        esac
    done
}

resolve_targets() {
    local targets_input="$ARG_FILTER_TARGETS"
    local config_targets=""
    local triples=()
    local archs=()
    local item=""
    local arch=""

    if [[ -z "$targets_input" ]]; then
        config_targets="$(echo "$CTX_CONFIG" | jq -r '.targets // [] | join(",")' 2>/dev/null)"
        if [[ -n "$config_targets" ]]; then
            targets_input="$config_targets"
        fi
    fi

    if [[ -z "$targets_input" ]]; then
        CTX_RESOLVED_TRIPLES=""
        CTX_RESOLVED_ARCHS="$(detect_targets_from_toolchain)"
        return
    fi

    IFS=',' read -r -a items <<<"$targets_input"
    for item in "${items[@]}"; do
        item="$(echo "$item" | xargs)"
        [[ -z "$item" ]] && continue
        triples+=("$item")

        arch=""
        case "$item" in
            *aarch64*) arch="aarch64" ;;
            *x86_64*) arch="x86_64" ;;
            *riscv64*) arch="riscv64" ;;
            *loongarch64*) arch="loongarch64" ;;
            *)
                log_warn "无法从 target '$item' 识别架构"
                continue
                ;;
        esac

        if [[ " ${archs[*]} " != *" $arch "* ]]; then
            archs+=("$arch")
        fi
    done

    CTX_RESOLVED_TRIPLES="${triples[*]}"
    if [[ ${#archs[@]} -eq 0 ]]; then
        CTX_RESOLVED_ARCHS="all"
    else
        CTX_RESOLVED_ARCHS="${archs[*]}"
    fi
}

cleanup() {
    local test_dir=""

    if [[ "$OPT_CLEANUP" != true || "$OPT_DRY_RUN" == true || ! -d "$CTX_OUTPUT_DIR/repos" ]]; then
        return
    fi

    log_debug "清理临时文件..."
    for test_dir in "$CTX_OUTPUT_DIR/repos"/*; do
        if [[ -d "$test_dir" ]]; then
            (cd "$test_dir" && git checkout Cargo.toml 2>/dev/null) || true
        fi
    done
}

show_banner() {
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Hypervisor Test Framework${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
}

handle_clean() {
    if [[ -z "$CTX_OUTPUT_DIR" ]]; then
        [[ -z "$CTX_COMPONENT_DIR" ]] && CTX_COMPONENT_DIR="$(pwd)"
        CTX_OUTPUT_DIR="$CTX_COMPONENT_DIR/test-results"
    fi

    if [[ -d "$CTX_OUTPUT_DIR" ]]; then
        log "清理测试目录: $CTX_OUTPUT_DIR"
        rm -rf "$CTX_OUTPUT_DIR"
        log_success "清理完成"
    else
        log "测试目录不存在: $CTX_OUTPUT_DIR"
    fi
}

handle_list_json() {
    load_config >/dev/null 2>&1
    echo "$CTX_CONFIG" | jq -c '[.test_targets[].name]'
}

handle_list_auto() {
    local targets=""

    exec 3>&2 2>/dev/null
    load_config
    resolve_targets
    targets="$(get_test_targets)"
    exec 2>&3 3>&-
    echo "$targets" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s -c
}

show_available_targets() {
    local count=0
    local i=0

    echo ""
    echo "所有可用的测试目标:"
    echo ""
    count="$(echo "$CTX_CONFIG" | jq '.test_targets | length')"
    for ((i = 0; i < count; i++)); do
        echo "  $(echo "$CTX_CONFIG" | jq -r ".test_targets[$i].name")"
    done
    echo ""
}

log_loaded_config() {
    log "配置加载完成"
    log "组件: $CTX_COMPONENT_NAME ($CTX_COMPONENT_CRATE)"
    [[ -n "$CTX_RESOLVED_TRIPLES" ]] && log_debug "Targets (triples): $CTX_RESOLVED_TRIPLES"
    [[ -n "$CTX_UNIT_TEST_TRIPLES" ]] && log_debug "Unit test targets: $CTX_UNIT_TEST_TRIPLES"
    log_debug "Targets (archs): $CTX_RESOLVED_ARCHS"
}

determine_test_plan() {
    RUN_UNIT=false
    RUN_INTEGRATION=false

    case "$ARG_TEST_MODE" in
        all)
            RUN_UNIT=true
            RUN_INTEGRATION=true
            ;;
        unit)
            RUN_UNIT=true
            ;;
        integration)
            RUN_INTEGRATION=true
            ;;
        *)
            error "无效的测试模式: $ARG_TEST_MODE (可选: all, unit, integration)"
            ;;
    esac
}

print_summary() {
    local run_unit="$1"
    local unit_result="$2"
    local run_integration="$3"
    local integration_result="$4"
    local final_result="$5"

    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  测试结果汇总${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"

    if [[ "$run_unit" == true ]]; then
        if [[ $unit_result -eq 0 ]]; then
            log_success "单元测试: 通过"
        elif [[ $unit_result -eq 2 ]]; then
            log_warn "单元测试: 跳过"
        else
            log_error "单元测试: 失败"
        fi
    fi

    if [[ "$run_integration" == true ]]; then
        if [[ $integration_result -eq 0 ]]; then
            log_success "集成测试: 通过"
        elif [[ $integration_result -eq 2 ]]; then
            log_warn "集成测试: 部分跳过"
        else
            log_error "集成测试: 部分失败"
        fi
    fi

    echo ""
    if [[ $final_result -eq 0 ]]; then
        log_success "所有测试通过!"
    else
        log_error "部分测试失败"
    fi
}

main() {
    local unit_result=0
    local integration_result=0
    local final_result=0

    parse_args "$@"

    if [[ "$OPT_CLEAN_RESULTS" == true ]]; then
        handle_clean
        exit 0
    fi

    if [[ "$OPT_LIST_JSON" == true ]]; then
        handle_list_json
        exit 0
    fi

    if [[ "$OPT_LIST_AUTO" == true ]]; then
        handle_list_auto
        exit 0
    fi

    show_banner

    check_dependencies
    load_config
    resolve_targets
    resolve_unit_test_targets
    log_loaded_config

    if [[ "$ARG_TEST_MODE" == "list" ]]; then
        show_available_targets
        exit 0
    fi

    setup_output
    log "输出目录: $CTX_OUTPUT_DIR"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        log_warn "DRY RUN 模式 - 不会执行实际操作"
    fi

    determine_test_plan

    if [[ "$RUN_UNIT" == true ]]; then
        echo ""
        log "========== 单元测试 =========="
        set +e
        run_unit_tests
        unit_result=$?
        set -e
    fi

    if [[ "$RUN_INTEGRATION" == true ]]; then
        echo ""
        log "========== 集成测试 =========="
        set +e
        run_all_tests
        integration_result=$?
        set -e
    fi

    if [[ "$RUN_UNIT" == true && $unit_result -ne 0 && $unit_result -ne 2 ]]; then
        final_result=1
    fi
    if [[ "$RUN_INTEGRATION" == true && $integration_result -ne 0 && $integration_result -ne 2 ]]; then
        final_result=1
    fi

    print_summary "$RUN_UNIT" "$unit_result" "$RUN_INTEGRATION" "$integration_result" "$final_result"
    exit "$final_result"
}

trap cleanup EXIT INT TERM

main "$@"
