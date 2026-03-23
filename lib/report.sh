#!/bin/bash
#
# report.sh - 测试报告生成
#
# 此文件负责生成 Markdown 格式的测试报告，包含:
#   - 测试概要信息 (组件名称、时间、配置)
#   - 结果汇总 (通过/失败/跳过数量)
#   - 单元测试和集成测试的详细结果
#
# 报告输出: $OUTPUT_DIR/report.md
#
# 使用方式: source "$SCRIPT_DIR/lib/report.sh"
#

SCRIPT_DIR_REPORT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_REPORT/lib/common.sh"

# =============================================================================
# 报告生成函数
# =============================================================================

# 生成测试报告
# 参数:
#   $1 - passed: 通过的测试数量
#   $2 - failed: 失败的测试数量
#   $3 - skipped: 跳过的测试数量
#
# 从 $OUTPUT_DIR/*.status 文件读取各测试的状态
# 生成 Markdown 格式的报告到 $OUTPUT_DIR/report.md
generate_report() {
    local passed=$1
    local failed=$2
    local skipped=$3
    local report_file="$CTX_OUTPUT_DIR/report.md"

    cat > "$report_file" << EOF
# 测试报告

**组件**: $CTX_COMPONENT_NAME
**时间**: $(date '+%Y-%m-%d %H:%M:%S')
**配置**: $CTX_CONFIG_FILE

## 结果汇总

| 状态 | 数量 |
|------|------|
| ✅ 通过 | $passed |
| ❌ 失败 | $failed |
| ⏭️ 跳过 | $skipped |

## 详细结果

EOF

    # 添加单元测试结果
    local unit_status_file="$CTX_OUTPUT_DIR/unit_tests.status"
    if [ -f "$unit_status_file" ]; then
        local unit_status=$(cat "$unit_status_file")
        echo "### 单元测试" >> "$report_file"
        if [ "$unit_status" == "passed" ]; then
            echo "- ✅ 通过" >> "$report_file"
        elif [ "$unit_status" == "skipped" ]; then
            echo "- ⏭️ 跳过" >> "$report_file"
        else
            echo "- ❌ 失败" >> "$report_file"
        fi
        echo "" >> "$report_file"
    fi

    # 添加集成测试结果
    local has_integration=false
    for status_file in "$CTX_OUTPUT_DIR"/*.status; do
        if [ -f "$status_file" ] && [ "$(basename "$status_file")" != "unit_tests.status" ]; then
            has_integration=true
            break
        fi
    done

    if [ "$has_integration" == true ]; then
        echo "### 集成测试" >> "$report_file"
        for status_file in "$CTX_OUTPUT_DIR"/*.status; do
            if [ -f "$status_file" ] && [ "$(basename "$status_file")" != "unit_tests.status" ]; then
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
    fi

    log_debug "报告已生成: $report_file"
}
