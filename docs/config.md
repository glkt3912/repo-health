# 設定リファレンス

## config.yml

`github.username` は個人情報のため **`config.yml` には持たない**。
環境変数または `.env` ファイルで設定する（必須）。

```yaml
# GitHub ユーザー名は環境変数 REPO_AUDIT_USERNAME または .env で設定する

thresholds:
  stale_months: 6           # これ以上 push がないと STALE 判定
  archive_months: 12        # これ以上 push がないと ARCHIVE 判定

always_active:              # 常に ACTIVE 扱い（除外リスト）
  - dotfiles
  - portfolio
  - nestjs-bff
  - subcheck
  - repo-health

report:
  output_dir: ~/repo-health-reports/   # --report-only 時のデフォルト保存先
```

## 各設定項目

### `REPO_AUDIT_USERNAME`（必須・環境変数のみ）

監査対象の GitHub アカウント名。`gh repo list <username>` に渡される。
`config.yml` には書かず、`.env` または環境変数で設定する。

```bash
# .env に記述（推奨）
echo 'REPO_AUDIT_USERNAME=your-username' >> .env

# または実行時に直接指定
REPO_AUDIT_USERNAME=your-username ./repo-audit.sh
```

未設定のまま実行するとエラーで終了し、設定方法が案内される。

### `thresholds.stale_months`

最後の push からこの月数を超えると 🟡 STALE 判定になる。デフォルトは `6`。

### `thresholds.archive_months`

最後の push からこの月数を超えると 🔴 ARCHIVE 判定になる。デフォルトは `12`。

`stale_months` と `archive_months` の間が STALE ゾーン、
`archive_months` 以上が ARCHIVE ゾーンになる。

### `always_active`

リスト内のリポジトリ名は push 日時にかかわらず 🟢 ACTIVE として扱われる。
デフォルトは空リスト (`[]`)。個人のリポジトリ名が含まれるため、`config.yml` には書かず
`.env` または環境変数での管理も検討すること（現状は `config.yml` のみ対応）。

```yaml
# 除外したいリポジトリを列挙する
always_active:
  - dotfiles        # 頻繁に push しないが常に使用中
  - portfolio       # 公開用で削除しない
  - this-repo-name  # 本ツール自身を評価対象外にする
```

### `report.output_dir`

`--report-only` フラグ単体（`--output` なし）で実行したときの保存先。
`~` はホームディレクトリに展開される。

## 環境変数によるオーバーライド

`config.yml` の値は環境変数で上書きできる。
優先順位は **環境変数 > config.yml > デフォルト値**。

| 環境変数 | 対応する config.yml キー | デフォルト値 |
| --- | --- | --- |
| `REPO_AUDIT_USERNAME` | `github.username` | （必須） |
| `REPO_AUDIT_STALE_MONTHS` | `thresholds.stale_months` | `6` |
| `REPO_AUDIT_ARCHIVE_MONTHS` | `thresholds.archive_months` | `12` |
| `REPO_AUDIT_OUTPUT_DIR` | `report.output_dir` | `~/repo-health-reports/` |
| `REPO_AUDIT_CONFIG` | — | `./config.yml` |

### 使い方

```bash
# 別の GitHub アカウントを一時的に監査
REPO_AUDIT_USERNAME=other-user ./repo-audit.sh --report-only

# しきい値を厳しくして実行（3ヶ月放置で STALE）
REPO_AUDIT_STALE_MONTHS=3 REPO_AUDIT_ARCHIVE_MONTHS=6 ./repo-audit.sh

# プロジェクトごとに別の config.yml を使う
REPO_AUDIT_CONFIG=~/configs/work-audit.yml ./repo-audit.sh

# CI/CD 環境でのレポート保存先を指定
REPO_AUDIT_OUTPUT_DIR=/tmp/reports ./repo-audit.sh --report-only
```

### GitHub Actions での設定例

環境変数は `env:` ブロックで渡せる。
secrets や変数として管理することで、リポジトリをフォークしても
ユーザー名をコードに埋め込まずに使いまわせる。

```yaml
- name: Run audit
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    REPO_AUDIT_USERNAME: ${{ vars.AUDIT_TARGET_USERNAME }}
    REPO_AUDIT_STALE_MONTHS: ${{ vars.STALE_MONTHS || '6' }}
  run: ./repo-audit.sh --report-only --output reports/
```

## yq が未インストールの場合

`yq` がない場合は `grep` + `sed` による簡易パースにフォールバックする。
簡易パースは `key: value` 形式の単純な値のみ対応しているため、
複雑な YAML 構造を追加する場合は `brew install yq` を推奨する。
