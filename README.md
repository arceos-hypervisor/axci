# Axci

共享 CI 工作流集合，用于 ArceOS Hypervisor 生态的各个 `no_std` 组件。

## 概述

### 设计

本仓库提供可复用的 GitHub Actions 工作流，组件仓库可以通过 `workflow_call` 引用这些工作流，避免在每个组件中重复维护 CI 配置。

**工作流列表：**

| 工作流 | 功能 |
|--------|------|
| `check.yml` | 代码质量检查（fmt、clippy、build、doc） |
| `test.yml` | 集成测试（通过 axtest 框架） |
| `verify-tag.yml` | 验证版本标签（分支、版本一致性） |
| `deploy.yml` | 部署文档到 GitHub Pages |
| `release.yml` | 创建 GitHub Release 并发布到 crates.io |

**目录结构：**

```
axci/
├── .github/
│   └── workflows/
│       ├── check.yml        # 代码检查
│       ├── test.yml         # 集成测试
│       ├── verify-tag.yml   # 标签验证
│       ├── deploy.yml       # 文档部署
│       └── release.yml      # 发布
└── README.md
```

## Check

### 设计

`check.yml` 工作流执行代码质量检查，确保代码符合规范并能正确编译。

**执行步骤：**
1. **代码格式检查** - `cargo fmt --check`
2. **编译检查** - `cargo build`
3. **Clippy 检查** - `cargo clippy`
4. **文档生成** - `cargo doc`

**输入参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `all_features` | 是否使用 --all-features 标志 | true |
| `targets` | 编译目标 (JSON 数组) | `["aarch64-unknown-none-softfloat"]` |
| `rust_components` | Rust 组件 (逗号分隔) | `rust-src, clippy, rustfmt, llvm-tools` |

### 使用

在组件仓库创建 `.github/workflows/check.yml`：

```yaml
name: Check

on:
  push:
    branches: ['**']
    tags-ignore: ['**']
  pull_request:

jobs:
  check:
    uses: arceos-hypervisor/axci/.github/workflows/check.yml@main
```

**带可选参数：**

```yaml
jobs:
  check:
    uses: arceos-hypervisor/axci/.github/workflows/check.yml@main
    with:
      all_features: false
      targets: '["aarch64-unknown-none"]'
      rust_components: 'rust-src, clippy'
```

## Deploy

### 设计

`deploy.yml` 工作流将文档部署到 GitHub Pages。

**执行步骤：**
1. 调用 `verify-tag.yml` 验证标签合法性
2. 生成文档
3. 部署到 GitHub Pages

**输入参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在 main/master 分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

### 使用

在组件仓库创建 `.github/workflows/deploy.yml`，推荐在版本标签推送时触发：

```yaml
name: Deploy

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

jobs:
  deploy:
    uses: arceos-hypervisor/axci/.github/workflows/deploy.yml@main
```

## Release

### 设计

`release.yml` 工作流创建 GitHub Release 并发布到 crates.io。

**执行步骤：**
1. 调用 `verify-tag.yml` 验证标签合法性
2. 发布到 crates.io
3. 创建 GitHub Release

**输入参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在正确分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

**Secrets：**

| Secret | 说明 |
|--------|------|
| `CARGO_REGISTRY_TOKEN` | crates.io 的 API token |

### 使用

在组件仓库创建 `.github/workflows/release.yml`，推荐在版本标签推送时触发：

```yaml
name: Release

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-pre.[0-9]+'

jobs:
  release:
    uses: arceos-hypervisor/axci/.github/workflows/release.yml@main
    secrets:
      CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

**版本发布流程：**

稳定版本：
```bash
# 1. 更新 Cargo.toml 中的版本号
# 2. 提交并推送到 main/master
git commit -am "chore: release v1.0.0"
git push origin main

# 3. 创建标签
git tag v1.0.0
git push origin v1.0.0
```

预发布版本：
```bash
# 1. 在 dev 分支工作
git checkout dev

# 2. 更新版本号
# 3. 提交并推送
git commit -am "chore: release v1.0.0-pre.1"
git push origin dev

# 4. 创建标签
git tag v1.0.0-pre.1
git push origin v1.0.0-pre.1
```

## Test

### 设计

`test.yml` 工作流运行集成测试，通过 patch 方式将组件集成到测试目标中构建验证。

**执行步骤：**
1. 检测或使用指定的 crate 名称
2. 克隆测试目标仓库
3. 通过 patch 方式集成组件
4. 构建并运行测试

**输入参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `crate_name` | 组件 crate 名称 | 自动检测 |
| `test_targets` | 测试目标（逗号分隔或 "all"） | all |
| `skip_build` | 跳过构建 | false |

**默认测试目标：**
- `axvisor` - https://github.com/arceos-hypervisor/axvisor
- `starry` - https://github.com/Starry-OS/StarryOS

### 使用

在组件仓库创建 `.github/workflows/test.yml`：

```yaml
name: Test

on:
  push:
    branches: [master, main, dev]
    tags-ignore: ['**']
  pull_request:
  workflow_dispatch:

jobs:
  test:
    uses: arceos-hypervisor/axci/.github/workflows/test.yml@main
```

**带可选参数：**

```yaml
jobs:
  test:
    uses: arceos-hypervisor/axci/.github/workflows/test.yml@main
    with:
      crate_name: 'arm_vcpu'
      test_targets: 'axvisor'
```

## 附录：verify-tag.yml

`verify-tag.yml` 是内部工作流，被 `deploy.yml` 和 `release.yml` 调用，用于验证版本标签的合法性。

**输入参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在正确分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

**输出：**

| 输出 | 说明 |
|------|------|
| `should_proceed` | 是否继续执行 deploy/release |
| `is_prerelease` | 是否为预发布标签 |

## License

Apache-2.0
