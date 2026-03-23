#!/bin/bash
#
# repo.sh - 仓库克隆与更新
#
# 此文件负责测试目标仓库的获取，支持两种方式:
#   1. cargo clone: 从 crates.io 下载发布版本 (axvisor 默认使用此方式)
#   2. git clone: 从 GitHub 克隆仓库 (starry 或指定 --from-git 时使用)
#
# 使用方式: source "$SCRIPT_DIR/lib/repo.sh"
#

SCRIPT_DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_REPO/lib/common.sh"

# =============================================================================
# 仓库操作函数
# =============================================================================

# 克隆或更新仓库
# 参数:
#   $1 - target_name: 测试目标名称 (如 axvisor-qemu-aarch64-arceos)
#   $2 - repo_url: 仓库 URL
#   $3 - repo_branch: 分支名称
#   $4 - test_dir: 本地测试目录路径
#   $5 - log_file: 日志文件路径
#   $6 - status_file: 状态文件路径 (用于记录失败状态)
# 返回: 0 成功, 1 失败
# 
# 特殊逻辑:
#   - axvisor-* 目标且未指定 --from-git 时，使用 cargo clone 从 crates.io 下载
#   - 其他情况使用 git clone --depth 1 浅克隆
#   - 如目录已存在则尝试 git pull 更新
clone_or_update_repo() {
    local target_name=$1
    local repo_url=$2
    local repo_branch=$3
    local test_dir=$4
    local log_file=$5
    local status_file=$6

    if [ ! -d "$test_dir" ]; then
        # 判断是否为 axvisor 目标，且未使用 --git 选项时，使用 cargo clone 从 crates.io 下载
        if [[ "$target_name" == axvisor-* ]] && [ "$OPT_USE_GIT" == false ]; then
            log "  从 crates.io 下载 axvisor..."
            if [ "$OPT_DRY_RUN" == true ]; then
                echo "[DRY-RUN] cargo clone axvisor -- $test_dir"
            else
                if ! cargo clone axvisor -- "$test_dir" >> "$log_file" 2>&1; then
                    log_error "  下载 axvisor 失败"
                    echo "failed" > "$status_file"
                    return 1
                fi
            fi
        else
            log "  克隆仓库..."
            if [ "$OPT_DRY_RUN" == true ]; then
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
        fi
    else
        log "  更新仓库..."
        if [ "$OPT_DRY_RUN" != true ]; then
            if [[ "$target_name" == axvisor-* ]] && [ "$OPT_USE_GIT" == false ]; then
                # axvisor 使用 cargo clone，不进行 git pull
                log "  axvisor 从 crates.io 下载，跳过更新"
            else
                (cd "$test_dir" && git pull) >> "$log_file" 2>&1 || true
            fi
        fi
    fi
}
