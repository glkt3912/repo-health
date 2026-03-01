# repo-health

GitHub リモートリポジトリの定期ヘルスチェックツール。

蓄積した古い・放置されたリポジトリを評価し、アーカイブ / 削除 / 整理を支援する。

## 機能

- **3段階の自動評価**: ACTIVE / STALE / ARCHIVE CANDIDATES
- **対話的アーカイブ**: `--interactive` で確認しながら `gh repo archive` 実行
- **description/topics 補完**: `--fix-meta` で空のメタデータを一括入力
- **Issue 自動作成**: `--create-issues` で STALE・ARCHIVE リポジトリに GitHub Issue を作成
  - オープンな Issue が既存の場合はスキップ（重複防止）
  - フォークリポジトリは対象外
  - 実行後に `repo-health` リポジトリへサマリー Issue を作成
- **月次自動実行**: macOS LaunchAgent または GitHub Actions で定期実行

## 評価ロジック

| 判定 | 条件 | アクション |
| --- | --- | --- |
| 🟢 ACTIVE | 6ヶ月以内に push | スキップ |
| 🟡 STALE | 6〜12ヶ月 push なし | GitHub Issue を自動作成 |
| 🔴 ARCHIVE | 12ヶ月以上 push なし | GitHub Issue を自動作成 + `gh repo archive` 実行候補 |

## セットアップ

```bash
# 依存: gh CLI + jq
brew install gh jq
gh auth login

# GitHub ユーザー名を設定（必須）
echo 'REPO_AUDIT_USERNAME=your-github-username' >> .env

# インストール（LaunchAgent も設定可）
./install.sh
```

## 使い方

```bash
# レポートを表示して操作を選択（デフォルト）
./repo-audit.sh

# レポートのみ表示（変更なし）
./repo-audit.sh --report-only

# ファイルに保存
./repo-audit.sh --report-only --output reports/

# 対話的にアーカイブ
./repo-audit.sh --interactive

# description/topics を一括補完
./repo-audit.sh --fix-meta

# STALE・ARCHIVE リポジトリに GitHub Issue を作成
./repo-audit.sh --create-issues
```

## 設定

GitHub ユーザー名は `config.yml` には書かない。実行環境に応じて設定する:

| 実行環境 | 設定方法 |
| --- | --- |
| ローカル | `.env` ファイルに `REPO_AUDIT_USERNAME=xxx` を記述 |
| GitHub Actions | Settings → Variables → Actions で `REPO_AUDIT_USERNAME` を登録 |
| 一時実行 | `REPO_AUDIT_USERNAME=xxx ./repo-audit.sh` |

しきい値や除外リストは `config.yml` で管理する:

```yaml
thresholds:
  stale_months: 6      # これ以上古いと STALE
  archive_months: 12   # これ以上古いと ARCHIVE 候補

always_active:         # 常にアクティブ扱い（除外）。デフォルトは空
  # - dotfiles
  # - portfolio
```

## 月次自動実行

### macOS LaunchAgent

`./install.sh` でセットアップ。毎月1日 9:00 AM に実行。
ログ: `~/repo-health-reports/logs/`

### GitHub Actions

`.github/workflows/monthly-audit.yml` が毎月1日 9:00 UTC に実行される。

**必要な設定:**

| 種別 | 名前 | 値 |
| --- | --- | --- |
| Secret | `GH_PAT` | Fine-grained PAT（Issues: Read and write） |
| Variable | `REPO_AUDIT_USERNAME` | GitHub ユーザー名 |

`GH_PAT` の作成: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens

**実行内容:**

1. 監査レポートを `reports/` にコミット
2. STALE・ARCHIVE リポジトリに Issue を自動作成
3. `repo-health` リポジトリにサマリー Issue を作成

手動トリガー: Actions タブ → "Monthly Repository Audit" → "Run workflow"

## レポート例

```text
=== GitHub Repository Audit: your-username (2026-03-01) ===

🟢 ACTIVE (8 repos)
  nestjs-bff                          TypeScript       pushed: 3 days ago           ✓ desc ✓ readme
  subcheck                            TypeScript       pushed: 1 week ago           ✓ desc ✓ readme

🟡 STALE (3 repos) — 放置気味
  rpg                                 Kotlin           pushed: 8 months ago         ✗ description なし ✓ readme
  gymeat                              Dart             pushed: 9 months ago         ✓ desc ✗ README なし

🔴 ARCHIVE CANDIDATES (2 repos)
  youtube-audio-downloader            JavaScript       pushed: 14 months ago        fork:false stars:0 ✗ description なし ✓ readme
  interior-planning-engine            Go               pushed: 18 months ago        fork:false stars:0 ✓ desc ✓ readme
```
