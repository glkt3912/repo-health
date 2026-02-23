# repo-health 概要

## 目的

`glkt3912` GitHub アカウントに蓄積した古い・放置されたリポジトリを
定期的に評価し、アーカイブ / 整理を支援する CLI ツール。

## 設計方針

- **リモート完結**: 操作対象はすべて GitHub 上のリモートリポジトリ。ローカルの `git` リポジトリは不要
- **`gh` CLI ベース**: GitHub API を直接叩かず、認証済みの `gh` コマンドを再利用
- **対話優先**: 自動削除・自動アーカイブは行わず、必ず人の確認を挟む
- **設定外だし**: `config.yml` でしきい値・除外リストを管理し、スクリプトを変更せずに挙動を調整できる

## 評価ロジック（3段階）

| 判定 | 条件 | 自動アクション |
| --- | --- | --- |
| 🟢 ACTIVE | `config.yml` の `stale_months`（デフォルト6ヶ月）以内に push | スキップ |
| 🟡 STALE | `stale_months` 〜 `archive_months` の間 push なし | `--create-issues` で GitHub Issue を作成 |
| 🔴 ARCHIVE | `archive_months`（デフォルト12ヶ月）以上 push なし | `--interactive` で確認しながらアーカイブ |

### 追加チェック項目

- `description` が空かどうか（ポートフォリオ品質の評価）
- `README.md` がルートに存在するか（`gh api repos/{owner}/{repo}/readme` で確認）
- fork リポジトリかつスター0（整理候補の判断基準）

### always_active 除外

`config.yml` の `always_active` リストに含まれるリポジトリは push 日時にかかわらず
常に🟢 ACTIVE として扱われる。本ツール自身 (`repo-health`) も除外対象に含まれている。

## ファイル構成

```
repo-health/
├── repo-audit.sh                      # メインスクリプト（gh + jq）
├── install.sh                         # macOS LaunchAgent 登録
├── config.yml                         # しきい値・除外リスト
├── docs/                              # MCP ドキュメント（本ドキュメント群）
├── .github/workflows/monthly-audit.yml  # GitHub Actions 月次自動実行
└── README.md
```

## 依存ツール

| ツール | 用途 | インストール |
| --- | --- | --- |
| `gh` | GitHub API 呼び出し・認証 | `brew install gh && gh auth login` |
| `jq` | JSON パース | `brew install jq` |
| `yq` | config.yml パース（任意） | `brew install yq` |
