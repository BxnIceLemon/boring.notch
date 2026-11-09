# Fork 开发约定

本仓库 [BxnIceLemon/boring.notch](https://github.com/BxnIceLemon/boring.notch) 是
[TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 的个人 fork，
用来开发自己的功能。

## 规则

- **永远不向上游合并。** 不向 TheBoredTeam/boring.notch 提交 Pull Request，不向上游推送任何分支。
- **只从上游同步。** 上游的改动单向流入本 fork（上游 → fork），反方向永远不发生。
- 本 fork 的功能、修复都只提交到 `fork` 远程。
- `CONTRIBUTING.md` 描述的是上游的贡献流程（向上游提 PR、Crowdin 翻译等），对本 fork 不适用。

## 远程仓库

| 远程名 | 地址 | 用途 |
|---|---|---|
| `origin` | `https://github.com/TheBoredTeam/boring.notch.git` | 上游，只用于 `fetch` |
| `fork` | `https://github.com/BxnIceLemon/boring.notch.git` | 本 fork，所有 `push` 都推到这里 |

本地克隆中 `origin` 的推送地址被设成了无效值，防止误推到上游：

```bash
git remote set-url --push origin DISABLED
```

`gh` 的默认仓库也设成了本 fork，`gh pr create` 等命令默认作用于 fork 而不是上游：

```bash
gh repo set-default BxnIceLemon/boring.notch
```

新克隆本仓库时需要重新做这些设置（远程和 gh 默认仓库都不随仓库提交）。从 fork 克隆时 `fork` 的地址就是 `origin`，建议改名以与本文保持一致：

```bash
git clone https://github.com/BxnIceLemon/boring.notch.git && cd boring.notch
git remote rename origin fork
git remote add origin https://github.com/TheBoredTeam/boring.notch.git
git remote set-url --push origin DISABLED
gh repo set-default BxnIceLemon/boring.notch
```

## 从上游同步

上游的发布分支是 `main`（`dev` 是上游的开发分支，一般不跟）。

```bash
git fetch origin
git checkout main
git merge origin/main
```

解决冲突、编译通过后推送到 fork：

```bash
git push fork main
```

功能分支再从更新后的 `main` 合并或变基即可。

同步时用 merge 而不是 rebase `main`：本 fork 的提交已推送到远程，变基会改写已发布的历史。

## 提交

- 提交作者邮箱使用 GitHub noreply 地址（`56258060+BxnIceLemon@users.noreply.github.com`）。
  账号开启了邮箱隐私保护，使用其他邮箱的提交会被 GitHub 拒绝推送。该设置已写入本仓库的本地 git 配置。
