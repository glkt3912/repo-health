# 自動化

## macOS LaunchAgent

`./install.sh` を実行すると、毎月1日 9:00 AM に `repo-audit.sh --report-only` を
自動実行する LaunchAgent を登録できる。

### plist の場所

```
~/Library/LaunchAgents/com.user.repo-health.plist
```

### 手動でのロード・アンロード

```bash
# ロード（install.sh が自動実行するが手動でも可）
launchctl load ~/Library/LaunchAgents/com.user.repo-health.plist

# アンロード（無効化）
launchctl unload ~/Library/LaunchAgents/com.user.repo-health.plist

# 即時テスト実行
launchctl start com.user.repo-health
```

### ログ確認

```bash
# 標準出力
cat ~/repo-health-reports/logs/repo-audit.log

# エラー出力
cat ~/repo-health-reports/logs/repo-audit-error.log
```

## GitHub Actions

`.github/workflows/monthly-audit.yml` で毎月1日 9:00 UTC に自動実行される。

### 実行フロー

1. `ubuntu-latest` で `jq` をインストール
2. `./repo-audit.sh --report-only --output reports/` でレポートを生成
3. `reports/audit-YYYY-MM.txt` を `chore: monthly audit report YYYY-MM` としてコミット
4. `./repo-audit.sh --create-issues` で STALE リポジトリに Issue を作成

### 手動トリガー

GitHub の Actions タブ → "Monthly Repository Audit" → "Run workflow" で手動実行できる。

### 必要な権限

`monthly-audit.yml` に以下を設定済み:

```yaml
permissions:
  contents: write   # reports/ へのコミットに必要
  issues: write     # Issue 作成に必要
```

デフォルトの `GITHUB_TOKEN` で動作するため、追加のシークレット設定は不要。

### reports/ の蓄積

毎月のレポートが `reports/audit-YYYY-MM-DD.txt` として git 管理される。
過去との比較や傾向把握に使える。

```
reports/
├── audit-2026-02-01.txt
├── audit-2026-03-01.txt
└── audit-2026-04-01.txt
```
