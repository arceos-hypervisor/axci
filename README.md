# Axci

共享 CI 工作流集合，用于 ArceOS Hypervisor 生态的各个 `no_std` 组件。

## 概述

本仓库提供可复用的 GitHub Actions 工作流，组件仓库可以通过 `workflow_call` 引用这些工作流，避免在每个组件中重复维护 CI 配置。

### 包含的工作流

| 工作流 | 功能 | 触发条件 |
|--------|------|----------|
| `check.yml` | 代码质量检查（fmt、clippy、build、doc） | push、PR |
| `test.yml` | 集成测试（通过 axtest 框架） | push、PR |
| `verify-tag.yml` | 验证版本标签（分支、版本一致性） | 被 deploy/release 调用 |
| `deploy.yml` | 部署文档到 GitHub Pages | 版本标签 |
| `release.yml` | 创建 GitHub Release 并发布到 crates.io | 版本标签 |

## 快速开始

### 1. 配置文件

在组件仓库创建 `.github/config.json`：

```json
{
  "$schema": "https://raw.githubusercontent.com/arceos-hypervisor/axtest/main/schema.json",
  "targets": ["aarch64-unknown-none-softfloat"],
  "rust_components": ["rust-src", "clippy", "rustfmt", "llvm-tools"],
  "component": {
    "name": "your_component",
    "crate_name": "your_component",
    "description": "Component description"
  },
  "test_targets": [
    {
      "name": "axvisor",
      "repo": {
        "url": "https://github.com/arceos-hypervisor/axvisor",
        "branch": "main"
      },
      "build": {
        "command": "make build A=examples/linux",
        "timeout_minutes": 15
      }
    }
  ]
}
```

### 2. 创建工作流文件

#### check.yml - 代码检查

```yaml
# .github/workflows/check.yml
name: Check

on:
  push:
    branches: ['**']
    tags-ignore: ['**']
  pull_request:

jobs:
  check:
    uses: arceos-hypervisor/axci/.github/workflows/check.yml@main
    with:
      all_features: true  # 可选，默认 true
```

#### test.yml - 集成测试

```yaml
# .github/workflows/test.yml
name: Test

on:
  push:
    branches: [master, main, dev]
    tags-ignore: ['**']
  pull_request:
  workflow_dispatch:
    inputs:
      test_targets:
        description: '测试目标 (all, axvisor, starry)'
        required: false
        default: 'all'
      skip_build:
        description: '跳过构建'
        required: false
        default: false
        type: boolean

jobs:
  test:
    uses: arceos-hypervisor/axci/.github/workflows/test.yml@main
    with:
      component_repo: ${{ github.repository }}
      component_ref: ${{ github.ref }}
      test_targets: ${{ inputs.test_targets || 'all' }}
      skip_build: ${{ inputs.skip_build || false }}
```

#### deploy.yml - 文档部署

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

jobs:
  deploy:
    uses: arceos-hypervisor/axci/.github/workflows/deploy.yml@main
    with:
      verify_branch: true   # 可选，默认 true
      verify_version: true  # 可选，默认 true
```

#### release.yml - 发布

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-pre.[0-9]+'

jobs:
  release:
    uses: arceos-hypervisor/axci/.github/workflows/release.yml@main
    with:
      verify_branch: true   # 可选，默认 true
      verify_version: true  # 可选，默认 true
    secrets:
      CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

### 3. 配置 Secrets

在组件仓库的 Settings → Secrets and variables → Actions 中添加：

- `CARGO_REGISTRY_TOKEN`: crates.io 的 API token（用于发布）

## 工作流详解

### check.yml

执行以下检查：
1. **代码格式检查** - `cargo fmt --check`
2. **编译检查** - `cargo build`
3. **Clippy 检查** - `cargo clippy`
4. **文档生成** - `cargo doc`

需要配置：
- `targets`: 编译目标列表
- `rust_components`: 需要安装的 Rust 组件

输入参数：
| 参数 | 说明 | 默认值 |
|------|------|--------|
| `all_features` | 是否使用 --all-features 标志 | true |

### test.yml

通过 axtest 框架执行集成测试。

输入参数：
| 参数 | 说明 | 默认值 |
|------|------|--------|
| `component_repo` | 组件仓库 | 必需 |
| `component_ref` | 组件引用 | 必需 |
| `test_targets` | 测试目标 | all |
| `skip_build` | 跳过构建 | false |

### verify-tag.yml

验证版本标签的合法性。

输入参数：
| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在正确分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

输出：
| 输出 | 说明 |
|------|------|
| `should_proceed` | 是否继续执行 deploy/release |
| `is_prerelease` | 是否为预发布标签 |

### deploy.yml

将文档部署到 GitHub Pages。

触发条件：
- 版本标签 `v*.*.*`
- 标签必须在 `main` 或 `master` 分支上（可通过 `verify_branch` 配置）

输入参数：
| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在 main/master 分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

### release.yml

创建 GitHub Release 并发布到 crates.io。

触发条件：
- 稳定版本：`v*.*.*`（必须在 main/master 分支）
- 预发布版本：`v*.*.*-pre.*`（必须在 dev 分支）

输入参数：
| 参数 | 说明 | 默认值 |
|------|------|--------|
| `verify_branch` | 验证标签是否在正确分支 | true |
| `verify_version` | 验证 Cargo.toml 版本与标签一致 | true |

## 版本发布流程

### 稳定版本

```bash
# 1. 更新 Cargo.toml 中的版本号
# 2. 提交并推送到 main/master
git commit -am "chore: release v1.0.0"
git push origin main

# 3. 创建标签
git tag v1.0.0
git push origin v1.0.0
```

### 预发布版本

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

## 目录结构

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

## 相关项目

- [axtest](https://github.com/arceos-hypervisor/axtest) - 共享测试框架

## License

Apache-2.0
