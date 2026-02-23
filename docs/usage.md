# 使い方

## セットアップ

```bash
# 依存をインストール
brew install gh jq
gh auth login

# LaunchAgent 登録（任意）
cd /Volumes/Dev-SSD/dev/repo-health
./install.sh
```

## コマンドリファレンス

### デフォルト実行（対話モード）

```bash
./repo-audit.sh
```

レポートを表示した後、以下の操作メニューを表示する。

```
Actions:
  [1] レポートを ~/repo-health-reports/ に保存
  [2] STALE リポジトリに GitHub Issue を作成
  [3] ARCHIVE 候補を対話的にアーカイブ
  [4] description/topics を一括編集モード
  [q] 終了
```

### `--report-only` — レポート表示のみ

```bash
./repo-audit.sh --report-only
```

変更を一切行わずレポートを表示し、`~/repo-health-reports/` に自動保存する。
GitHub Actions からの呼び出しや定期実行に適している。

### `--output DIR` — 保存先を指定

```bash
./repo-audit.sh --report-only --output reports/
```

`DIR/audit-YYYY-MM-DD.txt` にカラーコードなしで保存する。

### `--interactive` — 対話的アーカイブ

```bash
./repo-audit.sh --interactive
```

🔴 ARCHIVE 候補を1件ずつ表示し、確認を求める。

```
  youtube-audio-downloader
    Language : JavaScript
    Last push: 14 months ago
    Stars    : 0  Fork: false

  Archive glkt3912/youtube-audio-downloader? [y/N/q]:
```

- `y` → `gh repo archive glkt3912/<name> --yes` を実行
- `N` または Enter → スキップ
- `q` → 中断

### `--create-issues` — STALE Issue 自動作成

```bash
./repo-audit.sh --create-issues
```

🟡 STALE リポジトリそれぞれに対して、以下の Issue を作成する。

- タイトル: `🟡 Repository Health Check: 放置気味 (8 months ago)`
- ボディ: 状況説明 + 3つのチェックボックス（継続/アーカイブ/削除）
- ラベル: `maintenance`（ラベルが存在しない場合はスキップ）

### `--fix-meta` — description/topics 補完

```bash
./repo-audit.sh --fix-meta
```

`description` が空のリポジトリを順番に表示し、入力を促す。

```
  rpg (Kotlin, pushed: 8 months ago)
  Description を入力 (Enterでスキップ):
  Topics を入力 (カンマ区切り、Enterでスキップ):
```

- Description → `gh repo edit <name> --description "..."` を実行
- Topics → `gh repo edit <name> --add-topic <topic1> --add-topic <topic2>` を実行

## レポート出力例

```
=== GitHub Repository Audit: glkt3912 (2026-02-23) ===

🟢 ACTIVE (8 repos)
  nestjs-bff                          TypeScript       pushed: 3 days ago       ✓ desc ✓ readme
  subcheck                            TypeScript       pushed: 1 week ago       ✓ desc ✓ readme

🟡 STALE (3 repos) — 放置気味
  rpg                                 Kotlin           pushed: 8 months ago     ✗ description なし
  gymeat                              Dart             pushed: 9 months ago     ✗ README なし

🔴 ARCHIVE CANDIDATES (2 repos)
  youtube-audio-downloader            JavaScript       pushed: 14 months ago    fork:false stars:0
```

## 保存先

| 種類 | パス |
| --- | --- |
| レポートファイル | `~/repo-health-reports/audit-YYYY-MM-DD.txt` |
| LaunchAgent ログ | `~/repo-health-reports/logs/repo-audit.log` |
| LaunchAgent エラー | `~/repo-health-reports/logs/repo-audit-error.log` |
