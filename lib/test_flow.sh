#!/usr/bin/env bash
#
# test_flow.sh - 测试目标解析与执行流程
#
# 此文件是测试框架的核心，负责:
#   1. 目标三元组解析和架构映射
#   2. 单元测试目标解析
#   3. 测试套件过滤和解析
#   4. 构建和测试命令准备
#   5. 测试执行和状态收集
#
# 使用方式: source "$SCRIPT_DIR/lib/test_flow.sh"
#

# 防止重复加载
[[ -n "${_TEST_FLOW_SH_LOADED:-}" ]] && return 0
_TEST_FLOW_SH_LOADED=1

# =============================================================================
# 目标三元组辅助函数
# =============================================================================

# 判断目标三元组是否为 std 目标（支持标准库）
# 参数: $1 - triple: 目标三元组 (如 aarch64-unknown-linux-gnu)
# 返回: 0 是 std 目标, 1 是 no_std 目标
is_std_target_triple() {
    local triple="$1"

    case "$triple" in
        *-linux-*|*-darwin-*|*-windows-*|*-freebsd-*|*-netbsd-*|*-openbsd-*|*-dragonfly-*|*-android-*|*-ios-*)
            return 0
            ;;
        *-none-*|*-unknown-none|*-unknown-none-*|*-elf)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

get_arch_from_target_triple() {
    local triple="$1"

    case "$triple" in
        *aarch64*) echo "aarch64" ;;
        *x86_64*) echo "x86_64" ;;
        *riscv64*) echo "riscv64" ;;
        *loongarch64*) echo "loongarch64" ;;
        *) echo "" ;;
    esac
}

get_builtin_unit_target_map() {
    local triple="$1"

    case "$triple" in
        aarch64-unknown-none|aarch64-unknown-none-softfloat|aarch64-unknown-none-*)
            echo "aarch64-unknown-linux-gnu"
            ;;
        x86_64-unknown-none|x86_64-unknown-none-*)
            echo "x86_64-unknown-linux-gnu"
            ;;
        riscv64gc-unknown-none|riscv64gc-unknown-none-elf|riscv64gc-unknown-none-*)
            echo "riscv64gc-unknown-linux-gnu"
            ;;
        loongarch64-unknown-none|loongarch64-unknown-none-*|loongarch64-unknown-none-elf)
            echo "loongarch64-unknown-linux-gnu"
            ;;
        *) echo "" ;;
    esac
}

get_arch_fallback_unit_target() {
    local arch="$1"

    case "$arch" in
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        x86_64) echo "x86_64-unknown-linux-gnu" ;;
        riscv64) echo "riscv64gc-unknown-linux-gnu" ;;
        loongarch64) echo "loongarch64-unknown-linux-gnu" ;;
        *) echo "" ;;
    esac
}

# 将 no_std 目标三元组映射为可用于单元测试的 std 目标
# 参数: $1 - triple: no_std 目标三元组
# 输出: 映射后的 std 目标三元组
#
# 映射规则:
#   - 优先使用配置文件中的 unit_target_map
#   - 其次使用内置映射表
#   - 最后根据架构回退到默认值
map_no_std_to_unit_target() {
    local triple="$1"
    local mapped_target=""
    local arch=""

    mapped_target="$(echo "$CTX_CONFIG" | jq -r --arg triple "$triple" '.unit_target_map[$triple] // empty' 2>/dev/null)"
    if [[ -n "$mapped_target" ]]; then
        echo "$mapped_target"
        return
    fi

    mapped_target="$(get_builtin_unit_target_map "$triple")"
    if [[ -n "$mapped_target" ]]; then
        echo "$mapped_target"
        return
    fi

    arch="$(get_arch_from_target_triple "$triple")"
    if [[ -z "$arch" ]]; then
        echo ""
        return
    fi

    get_arch_fallback_unit_target "$arch"
}

# =============================================================================
# 单元测试目标解析
# =============================================================================

# 解析单元测试目标列表
# 从 RESOLVED_TRIPLES 中提取 std 目标，或将 no_std 目标映射为 std 目标
# 结果存储在全局变量 UNIT_TEST_TRIPLES 中
resolve_unit_test_targets() {
    local triples=()
    local triple=""
    local unit_target=""

    for triple in $CTX_RESOLVED_TRIPLES; do
        if is_std_target_triple "$triple"; then
            unit_target="$triple"
        else
            unit_target="$(map_no_std_to_unit_target "$triple")"
            if [[ -n "$unit_target" ]]; then
                log_debug "单元测试目标映射: $triple -> $unit_target"
            else
                log_debug "跳过 no_std 单元测试目标: $triple"
                continue
            fi
        fi

        if [[ " ${triples[*]} " != *" $unit_target "* ]]; then
            triples+=("$unit_target")
        fi
    done

    CTX_UNIT_TEST_TRIPLES="${triples[*]}"
}
# =============================================================================
# 测试套件解析
# =============================================================================

# 解析测试套件名称
# 根据 FILTER_SUITE 过滤配置中的测试目标
# 支持精确匹配和前缀匹配 (如 "axvisor-qemu" 匹配 "axvisor-qemu-*")
# 返回: 空格分隔的匹配套件名称列表
resolve_suites() {
    local suite_input="$ARG_FILTER_SUITE"
    local all_names=()
    local matched=()
    local count=0
    local i=0
    local name=""
    local pattern=""

    count="$(echo "$CTX_CONFIG" | jq '.test_targets | length')"
    for ((i = 0; i < count; i++)); do
        all_names+=("$(echo "$CTX_CONFIG" | jq -r ".test_targets[$i].name")")
    done

    if [[ -z "$suite_input" ]]; then
        echo "${all_names[*]}"
        return
    fi

    IFS=',' read -r -a patterns <<<"$suite_input"
    for name in "${all_names[@]}"; do
        for pattern in "${patterns[@]}"; do
            pattern="$(echo "$pattern" | xargs)"
            if [[ "$name" == "$pattern" || "$name" == "${pattern}-"* ]]; then
                matched+=("$name")
                break
            fi
        done
    done

    echo "${matched[*]}"
}

# 获取最终要执行的测试目标列表
# 综合考虑套件过滤和架构过滤
# 返回: 空格分隔的测试目标名称列表
get_test_targets() {
    local resolved_suites
    local targets=()
    local suite_name=""
    local target_arch=""
    local arch=""
    local arch_matched=false

    resolved_suites="$(resolve_suites)"
    log_debug "过滤架构: $CTX_RESOLVED_ARCHS"
    log_debug "过滤套件: $resolved_suites"

    for suite_name in $resolved_suites; do
        target_arch="$(echo "$CTX_CONFIG" | jq -r ".test_targets[] | select(.name == \"$suite_name\") | .arch")"
        arch_matched=false

        if [[ "$CTX_RESOLVED_ARCHS" == "all" ]]; then
            arch_matched=true
        else
            for arch in $CTX_RESOLVED_ARCHS; do
                if [[ "$target_arch" == "$arch" ]]; then
                    arch_matched=true
                    break
                fi
            done
        fi

        if [[ "$arch_matched" == true ]]; then
            targets+=("$suite_name")
        else
            log_warn "[SKIP] $suite_name: 架构 $target_arch 不在 targets [${CTX_RESOLVED_ARCHS// /, }] 中，跳过"
        fi
    done

    echo "${targets[*]}"
}

# =============================================================================
# 状态和命令辅助函数
# =============================================================================

# 写入测试状态到文件
# 参数:
#   $1 - status_file: 状态文件路径
#   $2 - status: 状态值 (passed/failed/skipped)
write_status() {
    local status_file="$1"
    local status="$2"
    echo "$status" >"$status_file"
}

# 执行 shell 命令（带超时）
# 参数:
#   $1 - workdir: 工作目录
#   $2 - command: 要执行的命令
#   $3 - timeout_min: 超时时间（分钟）
#   $4 - log_file: 日志文件路径
# 返回: 命令的退出码 (124 表示超时)
run_shell_command() {
    local workdir="$1"
    local command="$2"
    local timeout_min="$3"
    local log_file="$4"

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo "[DRY-RUN] cd $workdir && timeout ${timeout_min}m $command"
        return 0
    fi

    (
        cd "$workdir"
        timeout "${timeout_min}m" sh -c "$command"
    ) >>"$log_file" 2>&1
}

# =============================================================================
# 命令准备函数
# =============================================================================

# 准备构建命令
# 参数:
#   $1 - target_name: 测试目标名称
#   $2 - target_config: 测试目标配置
#   $3 - build_cmd: 原始构建命令
# 输出: 完整的构建命令到 stdout
#
# 特殊处理: StarryOS 目标需要附加 ARCH 参数
prepare_build_command() {
    local target_name="$1"
    local target_config="$2"
    local build_cmd="$3"

    if [[ "$target_name" == starry-* ]]; then
        local arch
        arch="$(echo "$target_config" | jq -r '.arch')"
        log "  构建架构: $arch"
        echo "$build_cmd ARCH=$arch"
        return
    fi

    echo "$build_cmd"
}

# 准备测试命令
# 参数:
#   $1 - target_name: 测试目标名称
#   $2 - target_config: 测试目标配置
#   $3 - test_dir: 测试目录路径
#   $4 - log_file: 日志文件路径
#   $5 - status_file: 状态文件路径
# 输出: 完整的测试命令到 stdout
#
# 根据目标类型调用对应的准备函数:
#   - axvisor-qemu-*: QEMU 镜像配置
#   - axvisor-board-*: 开发板镜像和 U-Boot 配置
#   - starry-*: 直接 make run
prepare_test_command() {
    local target_name="$1"
    local target_config="$2"
    local test_dir="$3"
    local log_file="$4"
    local status_file="$5"

    if [[ "$target_name" == axvisor-qemu-* ]]; then
        setup_qemu_images "$target_config" "$target_name" "$test_dir" "$log_file" "$status_file" || return 1
        prepare_qemu_command "$target_config"
        return
    fi

    if [[ "$target_name" == axvisor-board-* ]]; then
        setup_board_images "$target_config" "$target_name" "$test_dir" "$log_file" "$status_file" || return 1
        log "  生成构建配置..."
        setup_board_defconfig "$target_config" "$target_name" "$test_dir" "$log_file" "$status_file" || return 1
        setup_uboot_config "$target_config" "$test_dir"
        prepare_board_command "$target_config"
        return
    fi

    if [[ "$target_name" == starry-* ]]; then
        local arch
        arch="$(echo "$target_config" | jq -r '.arch')"
        echo "make ARCH=$arch run"
        return
    fi

    return 1
}

# =============================================================================
# 构建和测试执行函数
# =============================================================================

# 执行目标构建
# 参数:
#   $1 - target_name: 测试目标名称
#   $2 - target_config: 测试目标配置
#   $3 - test_dir: 测试目录路径
#   $4 - log_file: 日志文件路径
#   $5 - status_file: 状态文件路径
#   $6 - build_cmd: 构建命令
#   $7 - timeout_min: 超时时间（分钟）
# 返回: 0 成功, 1 失败
run_target_build() {
    local target_name="$1"
    local target_config="$2"
    local test_dir="$3"
    local log_file="$4"
    local status_file="$5"
    local build_cmd="$6"
    local timeout_min="$7"
    local exit_code=0

    [[ -z "$build_cmd" ]] && return 0

    log "  构建... ($build_cmd, timeout: ${timeout_min}m)"
    build_cmd="$(prepare_build_command "$target_name" "$target_config" "$build_cmd")"

    if run_shell_command "$test_dir" "$build_cmd" "$timeout_min" "$log_file"; then
        if [[ "$target_name" == starry-* && "$OPT_DRY_RUN" != true ]]; then
            local arch
            arch="$(echo "$target_config" | jq -r '.arch')"
            log "  准备 rootfs..."
            if run_shell_command "$test_dir" "make rootfs ARCH=$arch" "1" "$log_file"; then
                log "  Rootfs 准备完成"
            else
                exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    log_error "  Rootfs 准备超时，请检查网络环境"
                else
                    log_error "  Rootfs 准备失败（退出码: $exit_code）: $target_name"
                fi
                write_status "$status_file" "failed"
                return 1
            fi
        fi
        return 0
    fi

    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        log_error "  构建超时: $target_name"
    else
        log_error "  构建失败: $target_name (退出码: $exit_code)"
    fi
    write_status "$status_file" "failed"
    return 1
}

# 执行目标测试阶段
# 参数:
#   $1 - target_name: 测试目标名称
#   $2 - target_config: 测试目标配置
#   $3 - test_dir: 测试目录路径
#   $4 - log_file: 日志文件路径
#   $5 - status_file: 状态文件路径
#   $6 - test_type: 测试类型 (qemu/board)
#   $7 - test_cmd: 测试命令
#   $8 - test_timeout: 超时时间（分钟）
# 返回: 0 成功, 1 失败, 2 跳过
run_target_test_phase() {
    local target_name="$1"
    local target_config="$2"
    local test_dir="$3"
    local log_file="$4"
    local status_file="$5"
    local test_type="$6"
    local test_cmd="$7"
    local test_timeout="$8"

    log "  运行测试... ($test_cmd, timeout: ${test_timeout}m)"

    local full_test_cmd=""
    full_test_cmd="$(prepare_test_command "$target_name" "$target_config" "$test_dir" "$log_file" "$status_file")" || return 1

    if [[ "$OPT_DRY_RUN" == true ]]; then
        echo "[DRY-RUN] cd $test_dir && timeout ${test_timeout}m $full_test_cmd"
        write_status "$status_file" "skipped"
        return 2
    fi

    (
        cd "$test_dir"
        export RUST_LOG=debug

        if [[ "$test_type" == "board" ]]; then
            local board_name
            board_name="$(echo "$target_config" | jq -r '.board // empty')"
            run_with_success_detection "$full_test_cmd" "$test_timeout" "$log_file" "$board_name" "$test_dir"
        else
            run_with_success_detection "$full_test_cmd" "$test_timeout" "$log_file"
        fi
    )
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_success "  测试成功: $target_name"
        write_status "$status_file" "passed"
        return 0
    fi

    if [[ $exit_code -eq 124 ]]; then
        log_error "  测试超时（未检测到成功标识符）: $target_name"
    else
        log_error "  测试失败（退出码: $exit_code）: $target_name"
    fi
    write_status "$status_file" "failed"
    return 1
}

# =============================================================================
# 测试目标执行主函数
# =============================================================================

# 执行单个测试目标的完整流程
# 参数:
#   $1 - target_name: 测试目标名称
#   $2 - current_index: (可选) 当前索引，用于进度显示
#   $3 - total_count: (可选) 总目标数量
# 返回: 0 成功, 1 失败, 2 跳过
#
# 执行流程:
#   1. 清理端口 5555
#   2. 获取目标配置
#   3. 克隆/更新仓库
#   4. 检查组件依赖
#   5. 应用 patch
#   6. 执行构建
#   7. 执行测试
run_test_target() {
    local target_name="$1"
    local current_index="${2:-0}"
    local total_count="${3:-1}"
    local log_file="$CTX_OUTPUT_DIR/logs/${target_name}_$(date +%Y%m%d_%H%M%S).log"
    local status_file="$CTX_OUTPUT_DIR/${target_name}.status"
    local target_config=""
    local repo_url=""
    local repo_branch=""
    local test_type=""
    local build_cmd=""
    local timeout_min=""
    local has_test=""
    local test_cmd=""
    local test_timeout=""
    local test_dir="$CTX_OUTPUT_DIR/repos/$target_name"

    if [[ $total_count -gt 1 ]]; then
        log "[$current_index/$total_count] 测试目标: $target_name"
    else
        log "测试目标: $target_name"
    fi

    kill_port_5555_processes

    target_config="$(echo "$CTX_CONFIG" | jq -e ".test_targets[] | select(.name == \"$target_name\")")"
    if [[ -z "$target_config" ]]; then
        log_error "未找到测试目标配置: $target_name"
        write_status "$status_file" "failed"
        return 1
    fi

    repo_url="$(echo "$target_config" | jq -r '.repo.url')"
    repo_branch="$(echo "$target_config" | jq -r '.repo.branch // "main"')"
    test_type="$(echo "$target_config" | jq -r '.type // "qemu"')"
    build_cmd="$(echo "$target_config" | jq -r '.build.command')"
    timeout_min="$(echo "$target_config" | jq -r '.build.timeout_minutes // 15')"

    if [[ -n "$ARG_GIT_BRANCH" ]]; then
        repo_branch="$ARG_GIT_BRANCH"
        log "  使用指定分支: $repo_branch"
    fi

    log_debug "  仓库: $repo_url ($repo_branch)"
    log_debug "  类型: $test_type"
    log_debug "  构建: $build_cmd"
    log_debug "  超时: ${timeout_min}分钟"

    clone_or_update_repo "$target_name" "$repo_url" "$repo_branch" "$test_dir" "$log_file" "$status_file" || return 1

    if [[ "$OPT_DRY_RUN" != true && ! -d "$test_dir" ]]; then
        log_error "  仓库目录不存在: $test_dir"
        write_status "$status_file" "failed"
        return 1
    fi

    if [[ "$OPT_DRY_RUN" == true ]]; then
        log "  DRY RUN: 跳过 patch、构建和测试"
        write_status "$status_file" "skipped"
        return 2
    fi

    if [[ "$target_name" == axvisor-* || "$target_name" == starry-* ]]; then
        if ! check_component_used "$target_name" "$test_dir"; then
            log_warn "  跳过测试: 当前组件 '$CTX_COMPONENT_CRATE' 未在 $target_name 的依赖中使用 (搜索目录: $test_dir)"
            write_status "$status_file" "skipped"
            return 2
        fi
    fi

    if ! apply_component_patch "$target_config" "$test_dir"; then
        log_error "  Patch 应用失败: $target_name"
        write_status "$status_file" "failed"
        return 1
    fi

    run_target_build "$target_name" "$target_config" "$test_dir" "$log_file" "$status_file" "$build_cmd" "$timeout_min" || return 1

    has_test="$(echo "$target_config" | jq 'has("test")')"
    if [[ "$has_test" != "true" ]]; then
        log_success "  仅构建，无测试: $target_name"
        write_status "$status_file" "passed"
        return 0
    fi

    test_cmd="$(echo "$target_config" | jq -r '.test.command')"
    test_timeout="$(echo "$target_config" | jq -r '.test.timeout_minutes // 30')"
    run_target_test_phase "$target_name" "$target_config" "$test_dir" "$log_file" "$status_file" "$test_type" "$test_cmd" "$test_timeout"
}

# =============================================================================
# 单元测试函数
# =============================================================================

# 运行单元测试
# 对 UNIT_TEST_TRIPLES 中的每个目标执行 cargo test
# 返回: 0 全部通过, 1 部分失败, 2 跳过
run_unit_tests() {
    local log_file="$CTX_OUTPUT_DIR/logs/unit_tests_$(date +%Y%m%d_%H%M%S).log"
    local status_file="$CTX_OUTPUT_DIR/unit_tests.status"
    local all_passed=true
    local triple=""

    if [[ -z "$CTX_UNIT_TEST_TRIPLES" ]]; then
        log "跳过单元测试 (基础 targets 中没有可运行的 std target)"
        write_status "$status_file" "skipped"
        return 2
    fi

    log "运行单元测试..."
    log_debug "  日志文件: $log_file"

    cd "$CTX_COMPONENT_DIR"
    for triple in $CTX_UNIT_TEST_TRIPLES; do
        log "  cargo test --target $triple"
        if [[ "$OPT_DRY_RUN" == true ]]; then
            echo "[DRY-RUN] cd $CTX_COMPONENT_DIR && cargo test --target $triple"
            continue
        fi

        if cargo test --target "$triple" >>"$log_file" 2>&1; then
            log_success "  单元测试通过: $triple"
        else
            log_error "  单元测试失败: $triple (详见日志: $log_file)"
            all_passed=false
        fi
    done

    if [[ "$OPT_DRY_RUN" == true ]]; then
        write_status "$status_file" "skipped"
        return 2
    fi

    if [[ "$all_passed" == true ]]; then
        log_success "所有单元测试通过"
        write_status "$status_file" "passed"
        return 0
    fi

    log_error "部分单元测试失败"
    write_status "$status_file" "failed"
    return 1
}

# =============================================================================
# 状态收集和汇总函数
# =============================================================================

# 收集单个测试目标的状态
# 参数: $1 - target_name: 测试目标名称
# 返回: 状态值 (passed/failed/skipped)
collect_target_status() {
    local target_name="$1"
    local status_file="$CTX_OUTPUT_DIR/${target_name}.status"

    if [[ ! -f "$status_file" ]]; then
        echo "failed"
        return
    fi

    cat "$status_file"
}

# =============================================================================
# 测试执行入口函数
# =============================================================================

# 运行所有测试
# 主入口函数，执行完整的测试流程
# 返回: 0 全部通过, 1 有失败, 2 全部跳过
#
# 执行流程:
#   1. 获取测试目标列表
#   2. 根据 OPT_PARALLEL 决定并行或顺序执行
#   3. 收集测试结果
#   4. 生成测试报告
run_all_tests() {
    local targets=""
    local target_array=()
    local pids=()
    local pid=""
    local target=""
    local i=0
    local total_count=0
    local passed=0
    local failed=0
    local skipped=0
    local status=""
    local force_sequential=false

    targets="$(get_test_targets)"
    read -r -a target_array <<<"$targets"
    total_count="${#target_array[@]}"

    log "测试目标: ${target_array[*]}"
    echo ""

    if [[ $total_count -gt 3 ]]; then
        force_sequential=true
    fi

    if [[ "$OPT_PARALLEL" == true && $total_count -gt 1 && "$force_sequential" == false ]]; then
        for i in "${!target_array[@]}"; do
            target="${target_array[$i]}"
            run_test_target "$target" "$((i + 1))" "$total_count" &
            pids+=("$!")
        done

        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done

        for target in "${target_array[@]}"; do
            status="$(collect_target_status "$target")"
            case "$status" in
                passed) passed=$((passed + 1)) ;;
                skipped) skipped=$((skipped + 1)) ;;
                *) failed=$((failed + 1)) ;;
            esac
        done
    else
        for i in "${!target_array[@]}"; do
            target="${target_array[$i]}"
            set +e
            run_test_target "$target" "$((i + 1))" "$total_count"
            set -e
            status="$(collect_target_status "$target")"
            case "$status" in
                passed) passed=$((passed + 1)) ;;
                skipped) skipped=$((skipped + 1)) ;;
                *) failed=$((failed + 1)) ;;
            esac
        done
    fi

    echo ""
    log "测试结果:"
    echo "  - 通过: $passed"
    echo "  - 失败: $failed"
    echo "  - 跳过: $skipped"

    generate_report "$passed" "$failed" "$skipped"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    if [[ $passed -eq 0 && $skipped -gt 0 ]]; then
        return 2
    fi
    return 0
}
