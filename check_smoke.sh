#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
TARGET_SCRIPT="${SCRIPT_DIR}/check.sh"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "ASSERTION FAILED: $message" >&2
        echo "missing: $needle" >&2
        echo "actual: $haystack" >&2
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ASSERTION FAILED: $message" >&2
        echo "unexpected: $needle" >&2
        echo "actual: $haystack" >&2
        exit 1
    fi
}

assert_json_eq() {
    local expected_json="$1"
    local actual_json="$2"
    local message="$3"

    local expected_sorted
    local actual_sorted
    expected_sorted=$(echo "$expected_json" | jq -c 'sort')
    actual_sorted=$(echo "$actual_json" | jq -c 'sort')
    if [[ "$expected_sorted" != "$actual_sorted" ]]; then
        echo "ASSERTION FAILED: $message" >&2
        echo "expected: $expected_sorted" >&2
        echo "actual:   $actual_sorted" >&2
        exit 1
    fi
}

make_component_dir() {
    local dir
    dir="$(mktemp -d)"

    cat > "${dir}/Cargo.toml" <<'EOF'
[package]
name = "check-smoke-component"
version = "0.1.0"
edition = "2021"
EOF

    mkdir -p "${dir}/src"
    cat > "${dir}/src/lib.rs" <<'EOF'
pub fn smoke() -> bool {
    true
}
EOF

    mkdir -p "${dir}/.github"

    echo "${dir}"
}

write_config() {
    local component_dir="$1"
    local config_json="$2"

    cat > "${component_dir}/.github/config.json" <<EOF
$config_json
EOF
}

make_fake_bin() {
    local dir
    dir="$(mktemp -d)"

    cat > "${dir}/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo $*" >> "${CARGO_LOG_FILE}"
case "$1" in
  fmt|build|clippy|doc) exit 0 ;;
  *) echo "unexpected cargo command: $*" >&2; exit 1 ;;
esac
EOF
    chmod +x "${dir}/cargo"

    echo "${dir}"
}

run_check() {
    local component_dir="$1"
    shift

    local fake_bin
    fake_bin="$(make_fake_bin)"
    local cargo_log
    cargo_log="$(mktemp)"

    PATH="${fake_bin}:${PATH}" \
    CARGO_LOG_FILE="${cargo_log}" \
    bash "${TARGET_SCRIPT}" --component-dir "${component_dir}" "$@" >/dev/null

    cat "${cargo_log}"

    rm -rf "${fake_bin}"
    rm -f "${cargo_log}"
}

run_check_stdout() {
    local component_dir="$1"
    shift

    local fake_bin
    fake_bin="$(make_fake_bin)"
    local cargo_log
    cargo_log="$(mktemp)"

    PATH="${fake_bin}:${PATH}" \
    CARGO_LOG_FILE="${cargo_log}" \
    bash "${TARGET_SCRIPT}" --component-dir "${component_dir}" "$@"

    cat "${cargo_log}"

    rm -rf "${fake_bin}"
    rm -f "${cargo_log}"
}

test_skip_build_and_disable_all_features() {
    local component_dir
    component_dir="$(make_component_dir)"
    trap 'rm -rf "${component_dir}"' RETURN

    local log
    log="$(run_check "${component_dir}" --targets aarch64-unknown-none-softfloat --skip-build --no-all-features)"

    assert_contains "${log}" "cargo fmt --all -- --check" "fmt should run"
    assert_contains "${log}" "cargo clippy --target aarch64-unknown-none-softfloat -- -D warnings" "clippy should omit --all-features when disabled"
    assert_contains "${log}" "cargo doc --no-deps --target aarch64-unknown-none-softfloat" "doc should run for the requested target"
    assert_not_contains "${log}" "cargo build --target" "build should be skipped when --skip-build is set"
    assert_not_contains "${log}" "--all-features" "no cargo command should include --all-features when disabled"

    rm -rf "${component_dir}"
    trap - RETURN
}

test_list_targets_json() {
    local component_dir
    component_dir="$(make_component_dir)"
    trap 'rm -rf "${component_dir}"' RETURN

    write_config "${component_dir}" '{
  "targets": [
    "aarch64-unknown-none-softfloat",
    "x86_64-unknown-none"
  ]
}'

    local json_output
    json_output="$(bash "${TARGET_SCRIPT}" --component-dir "${component_dir}" --list-targets-json)"
    assert_json_eq '["aarch64-unknown-none-softfloat","x86_64-unknown-none"]' "${json_output}" "list-targets-json should expose resolved targets for the workflow"

    rm -rf "${component_dir}"
    trap - RETURN
}

test_only_clippy_stage() {
    local component_dir
    component_dir="$(make_component_dir)"
    trap 'rm -rf "${component_dir}"' RETURN

    local log
    log="$(run_check "${component_dir}" --targets aarch64-unknown-none-softfloat --only clippy)"

    assert_contains "${log}" "cargo clippy --target aarch64-unknown-none-softfloat --all-features -- -D warnings" "clippy-only mode should run clippy"
    assert_not_contains "${log}" "cargo fmt --all -- --check" "clippy-only mode should skip fmt"
    assert_not_contains "${log}" "cargo build --target" "clippy-only mode should skip build"
    assert_not_contains "${log}" "cargo doc --no-deps --target" "clippy-only mode should skip doc"

    rm -rf "${component_dir}"
    trap - RETURN
}

main() {
    test_skip_build_and_disable_all_features
    test_list_targets_json
    test_only_clippy_stage
    echo "check smoke tests passed"
}

main "$@"
