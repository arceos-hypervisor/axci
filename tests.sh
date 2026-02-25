#!/bin/bash
#
# Hypervisor Test Framework - 本地测试脚本
# 此脚本可独立运行，也可被各组件调用
#
# 用法:
#   ./run_tests.sh                           # 运行所有测试
#   ./run_tests.sh --target axvisor          # 仅测试指定目标
#   ./run_tests.sh --config /path/to/.test-config.json
#   ./run_tests.sh --component-dir /path/to/component
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

用法: tests.sh [选项]

选项:
  -c, --component-dir DIR    组件目录 (默认: 当前目录)
  -f, --config FILE          配置文件路径 (可选，默认使用内置测试目标)
  -t, --target TARGET        测试目标: all 或指定名称 (默认: all)
  -o, --output DIR           输出目录 (默认: COMPONENT_DIR/test-results)
  -v, --verbose              详细输出
  --no-cleanup               不清理临时文件
  --dry-run                  仅显示将要执行的命令
  --sequential               顺序执行测试 (不并行)
  -h, --help                 显示此帮助

示例:
  tests.sh                                    # 在当前目录运行所有测试
  tests.sh -c ../arm_vcpu -t axvisor          # 测试 arm_vcpu 的 axvisor 集成
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
log_debug() { [[ "$VERBOSE" == true ]] && echo -e "${CYAN}[DEBUG]${NC} $1"; }

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
    "name": "axvisor",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "main"},
    "build": {"command": "make build A=examples/linux", "timeout_minutes": 15},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
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
    else
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
    local build_cmd=$(echo "$target_config" | jq -r '.build.command')
    local timeout_min=$(echo "$target_config" | jq -r '.build.timeout_minutes // 15')
    
    log_debug "  仓库: $repo_url ($repo_branch)"
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
            git clone --depth 1 -b $repo_branch "$repo_url" "$test_dir" >> "$log_file" 2>&1
        fi
    else
        log "  更新仓库..."
        if [ "$DRY_RUN" != true ]; then
            (cd "$test_dir" && git pull) >> "$log_file" 2>&1 || true
        fi
    fi
    
    # 应用 patch - 与 CI 逻辑保持一致
    # 优先级: 目标配置 > 全局配置 > 默认值
    local patch_section=$(echo "$target_config" | jq -r '.patch.section // empty')
    [ -z "$patch_section" ] && patch_section=$(echo "$CONFIG" | jq -r '.patch.section // "crates-io"')
    
    local patch_path=$(echo "$target_config" | jq -r '.patch.path_template // empty')
    [ -z "$patch_path" ] && patch_path=$(echo "$CONFIG" | jq -r '.patch.path_template // "../component"')
    
    # 转换为绝对路径
    if [[ "$patch_path" == ".."* ]]; then
        patch_path="$(cd "$test_dir/$patch_path" 2>/dev/null && pwd)" || {
            log_error "无法解析 patch 路径: $test_dir/$patch_path"
            echo "failed" > "$status_file"
            return 1
        }
    fi
    
    log "  应用组件 patch (section: $patch_section, path: $patch_path)..."
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] 添加 patch 到 $test_dir/Cargo.toml"
    else
        cd "$test_dir"
        
        # 检查是否已添加 patch
        if ! grep -q "\[$COMPONENT_CRATE\]" Cargo.toml 2>/dev/null; then
            cat >> Cargo.toml << EOF

[patch.$patch_section]
$COMPONENT_CRATE = { path = "$patch_path" }
EOF
            log_debug "已添加 patch 到 Cargo.toml"
        fi
    fi
    
    # 执行构建
    log "  构建... ($build_cmd, timeout: ${timeout_min}m)"
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] cd $test_dir && timeout ${timeout_min}m $build_cmd"
    else
        cd "$test_dir"
        if timeout "${timeout_min}m" sh -c "$build_cmd" >> "$log_file" 2>&1; then
            log_success "  构建成功: $target_name"
            echo "passed" > "$status_file"
            cd "$COMPONENT_DIR"
            return 0
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
}

# 运行所有测试
run_all_tests() {
    local targets=$(get_test_targets)
    local failed=0
    local passed=0
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
            if run_test_target "$target"; then
                ((passed++))
            else
                ((failed++))
            fi
        done
    fi
    
    echo ""
    log "测试结果:"
    echo "  - 通过: $passed"
    echo "  - 失败: $failed"
    
    # 生成报告
    generate_report "$passed" "$failed"
    
    if [ $failed -gt 0 ]; then
        return 1
    fi
    return 0
}

# 生成报告
generate_report() {
    local passed=$1
    local failed=$2
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

## 详细结果

EOF
    
    for status_file in "$OUTPUT_DIR"/*.status; do
        if [ -f "$status_file" ]; then
            local name=$(basename "$status_file" .status)
            local status=$(cat "$status_file")
            if [ "$status" == "passed" ]; then
                echo "- $name: ✅ 通过" >> "$report_file"
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
    setup_output
    
    if [ "$DRY_RUN" == true ]; then
        log_warn "DRY RUN 模式 - 不会执行实际操作"
    fi
    
    run_all_tests
    local result=$?
    
    cleanup
    
    echo ""
    if [ $result -eq 0 ]; then
        log_success "所有测试通过!"
    else
        log_error "部分测试失败"
    fi
    
    exit $result
}

# 捕获信号
trap cleanup EXIT INT TERM

main "$@"
