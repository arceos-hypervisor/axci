#!/bin/bash
#
# patch.sh - 组件依赖检查和 Cargo patch 应用
#

SCRIPT_DIR_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_PATCH/lib/common.sh"

# 检查组件是否被目标项目使用（从 Cargo.lock 中检索）
# 返回 0 表示使用，1 表示未使用
check_component_used() {
    local target_name=$1
    local test_dir=$2

    # 如果不是 axvisor 或 starry 相关的测试，直接返回使用
    if [[ "$target_name" != axvisor-* ]] && [[ "$target_name" != starry-* ]]; then
        return 0
    fi

    local cargo_lock="$test_dir/Cargo.lock"

    # 如果 Cargo.lock 不存在，尝试从 Cargo.toml 检查
    if [ ! -f "$cargo_lock" ]; then
        local cargo_toml="$test_dir/Cargo.toml"
        if [ ! -f "$cargo_toml" ]; then
            log_warn "  未找到 Cargo.toml 或 Cargo.lock，无法检查依赖关系"
            return 0
        fi

        # 从 Cargo.toml 检查是否有该组件的依赖
        if grep -q "^$COMPONENT_CRATE\s*=" "$cargo_toml" 2>/dev/null; then
            log_debug "  在 Cargo.toml 中找到组件: $COMPONENT_CRATE"
            return 0
        fi

        # 检查 workspace members 是否可能包含该组件
        if grep -q "^$COMPONENT_CRATE\s*=" "$test_dir"/*/Cargo.toml 2>/dev/null; then
            log_debug "  在 workspace member 中找到组件: $COMPONENT_CRATE"
            return 0
        fi

        return 1
    fi

    # 从 Cargo.lock 中检查组件
    # Cargo.lock 格式：[[package]] name = "crate-name"
    if grep -A 1 '^\[\[package\]\]' "$cargo_lock" 2>/dev/null | grep -q "name = \"$COMPONENT_CRATE\""; then
        log_debug "  在 Cargo.lock 中找到组件: $COMPONENT_CRATE"
        return 0
    fi

    # 如果直接没找到，尝试从 Cargo.toml 再确认一下（可能是间接依赖）
    local cargo_toml="$test_dir/Cargo.toml"
    if [ -f "$cargo_toml" ] && grep -q "^$COMPONENT_CRATE\s*=" "$cargo_toml" 2>/dev/null; then
        log_debug "  在 Cargo.toml 中找到组件: $COMPONENT_CRATE"
        return 0
    fi

    return 1
}

# 应用组件 patch 到目标项目的 Cargo.toml
# 参数: target_config, test_dir
apply_component_patch() {
    local target_config=$1
    local test_dir=$2

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
            patch_path="$COMPONENT_DIR"
        fi
    fi

    log "  应用组件 patch (section: $patch_section, path: $patch_path)..."
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] 添加 patch 到 $test_dir/Cargo.toml"
    else
        cd "$test_dir"

        # 检查是否已添加该组件的 patch（只在 [patch.*] section 中检查）
        if grep -E "^\[patch\." Cargo.toml >/dev/null 2>&1 && \
           grep -A 100 "^\[patch\." Cargo.toml | grep -q "^$COMPONENT_CRATE\s*="; then
            log "  组件 $COMPONENT_CRATE 已在 patch 中"
        else
            # 检查是否已存在 [patch.$patch_section] section
            if grep -q "^\[patch\.$patch_section\]" Cargo.toml 2>/dev/null; then
                # 在现有的 section 后添加
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
}
