#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# repo-audit: GitHub リポジトリ定期ヘルスチェック
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env があれば読み込む
# 優先順位: シェル環境変数 > .env > config.yml > デフォルト値
# → 既にシェルで設定済みの変数は .env で上書きしない
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    _key="${BASH_REMATCH[1]}"
    _val="${BASH_REMATCH[2]}"
    # 引用符を除去
    _val="${_val#\"}" ; _val="${_val%\"}"
    _val="${_val#\'}" ; _val="${_val%\'}"
    # 既に設定済みの変数はスキップ
    [[ -n "${!_key+x}" ]] && continue
    export "${_key}=${_val}"
  done < "${SCRIPT_DIR}/.env"
  unset _key _val
fi

CONFIG_FILE="${REPO_AUDIT_CONFIG:-${SCRIPT_DIR}/config.yml}"

# ─── カラー出力 ───
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── フラグ ───
REPORT_ONLY=false
CREATE_ISSUES=false
INTERACTIVE=false
FIX_META=false
AUTO_ARCHIVE=false
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
Usage: ./repo-audit.sh [OPTIONS]

GitHub リポジトリのヘルスチェックを実行する。

Options:
  --report-only       レポートを表示するだけ（変更なし）
  --output DIR        レポートをファイルに保存
  --create-issues     STALE リポジトリに GitHub Issue を作成
  --interactive       ARCHIVE 候補を対話的にアーカイブ
  --auto-archive      ARCHIVE 候補を自動アーカイブ（CI向け・非対話型）
                      アーカイブ前に description と README にアーカイブ理由を記録する
  --fix-meta          description/topics を一括補完モード
  -h, --help          このヘルプを表示

Environment variables (config.yml の値を上書き):
  REPO_AUDIT_USERNAME       監査対象の GitHub ユーザー名
  REPO_AUDIT_STALE_MONTHS   STALE 判定の月数 (デフォルト: 6)
  REPO_AUDIT_ARCHIVE_MONTHS ARCHIVE 判定の月数 (デフォルト: 12)
  REPO_AUDIT_OUTPUT_DIR     レポートの保存先ディレクトリ
  REPO_AUDIT_CONFIG         config.yml のパス (デフォルト: ./config.yml)

Examples:
  ./repo-audit.sh                                      # デフォルト: レポート表示
  ./repo-audit.sh --interactive                        # 対話的にアーカイブ
  ./repo-audit.sh --fix-meta                           # description/topics 補完
  ./repo-audit.sh --report-only --output reports/      # ファイルに保存
  ./repo-audit.sh --create-issues                      # STALE に Issue を自動作成
  ./repo-audit.sh --auto-archive                       # ARCHIVE 候補を自動アーカイブ（CI向け）
  REPO_AUDIT_USERNAME=other-user ./repo-audit.sh       # 別アカウントを監査
  REPO_AUDIT_STALE_MONTHS=3 ./repo-audit.sh            # しきい値を一時変更
USAGE
}

# ─── 引数パース ───
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-only)    REPORT_ONLY=true; shift ;;
    --create-issues)  CREATE_ISSUES=true; shift ;;
    --interactive)    INTERACTIVE=true; shift ;;
    --auto-archive)   AUTO_ARCHIVE=true; shift ;;
    --fix-meta)       FIX_META=true; shift ;;
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*) echo "Unknown option: $1"; usage; exit 1 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ─── 依存チェック ───
for cmd in gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: ${cmd} is required.${NC}"
    [[ "$cmd" == "gh" ]] && echo "  Install: https://cli.github.com/"
    [[ "$cmd" == "jq" ]] && echo "  Install: brew install jq"
    exit 1
  fi
done

# ─── config.yml パース (yq があれば使用、なければ grep/sed で簡易パース) ───
parse_config() {
  local key="$1"
  if command -v yq &>/dev/null; then
    local val
    val=$(yq -r ".${key}" "${CONFIG_FILE}" 2>/dev/null || echo "")
    [[ "$val" == "null" ]] && val=""
    echo "$val"
  else
    # 簡易パース: ネストキー (foo.bar) の末尾部分で grep
    local leaf="${key##*.}"
    grep -E "^\s+${leaf}:" "${CONFIG_FILE}" 2>/dev/null | sed 's/.*: *//' | tr -d '"' || echo ""
  fi
}

# 優先順位: 環境変数 > config.yml > デフォルト値
# username は config.yml には持たず、環境変数または .env で必須設定
_cfg_stale="$(parse_config 'thresholds.stale_months')"
_cfg_archive="$(parse_config 'thresholds.archive_months')"
_cfg_output_dir="$(parse_config 'report.output_dir' | sed "s|~|${HOME}|g")"
_cfg_update_desc="$(parse_config 'archive.update_description')"
_cfg_update_readme="$(parse_config 'archive.update_readme')"
_cfg_desc_prefix="$(parse_config 'archive.description_prefix')"

USERNAME="${REPO_AUDIT_USERNAME:-}"
STALE_MONTHS="${REPO_AUDIT_STALE_MONTHS:-${_cfg_stale:-6}}"
ARCHIVE_MONTHS="${REPO_AUDIT_ARCHIVE_MONTHS:-${_cfg_archive:-12}}"
REPORT_OUTPUT_DIR="${REPO_AUDIT_OUTPUT_DIR:-${_cfg_output_dir:-${HOME}/repo-health-reports/}}"
ARCHIVE_UPDATE_DESC="${REPO_AUDIT_ARCHIVE_UPDATE_DESC:-${_cfg_update_desc:-true}}"
ARCHIVE_UPDATE_README="${REPO_AUDIT_ARCHIVE_UPDATE_README:-${_cfg_update_readme:-true}}"
ARCHIVE_DESC_PREFIX="${REPO_AUDIT_ARCHIVE_DESC_PREFIX:-${_cfg_desc_prefix:-[Archived by repo-health]}}"

# USERNAME が未設定の場合は設定方法を案内して終了
if [[ -z "${USERNAME}" ]]; then
  echo -e "${RED}Error: GitHub username is not set.${NC}"
  echo ""
  echo "Set it via:"
  echo "  1. Environment variable:  REPO_AUDIT_USERNAME=your-username ./repo-audit.sh"
  echo "  2. .env file:             echo 'REPO_AUDIT_USERNAME=your-username' >> .env"
  exit 1
fi

# config.yml から always_active リストを抽出
ALWAYS_ACTIVE=()
while IFS= read -r line; do
  repo="$(echo "$line" | sed 's/.*- *//' | tr -d '"' | tr -d ' ')"
  [[ -n "$repo" ]] && ALWAYS_ACTIVE+=("$repo")
done < <(awk '/always_active:/,/^[^ ]/' "${CONFIG_FILE}" | grep '^\s*-')

# ─── 日付計算 ───
NOW_EPOCH="$(date +%s)"

months_ago_epoch() {
  local months="$1"
  # macOS の date コマンドに対応
  if date --version &>/dev/null 2>&1; then
    # GNU date
    date --date="${months} months ago" +%s
  else
    # macOS date
    date -v "-${months}m" +%s
  fi
}

STALE_EPOCH="$(months_ago_epoch "${STALE_MONTHS}")"
ARCHIVE_EPOCH="$(months_ago_epoch "${ARCHIVE_MONTHS}")"

# ─── リポジトリ情報取得 ───
echo -e "${BOLD}Fetching repositories for ${USERNAME}...${NC}"

REPOS_JSON="$(gh repo list "${USERNAME}" --limit 200 \
  --json name,updatedAt,pushedAt,stargazerCount,isArchived,\
isFork,primaryLanguage,description,diskUsage,visibility 2>/dev/null)"

TOTAL="$(echo "${REPOS_JSON}" | jq length)"
echo -e "  Found ${TOTAL} repositories"
echo ""

# ─── 分類処理 ───
ACTIVE_REPOS=()
STALE_REPOS=()
ARCHIVE_REPOS=()

declare -A REPO_PUSHED
declare -A REPO_LANG
declare -A REPO_STARS
declare -A REPO_IS_FORK
declare -A REPO_DESC
declare -A REPO_HAS_README

is_always_active() {
  local name="$1"
  for active in "${ALWAYS_ACTIVE[@]}"; do
    [[ "$active" == "$name" ]] && return 0
  done
  return 1
}

# README 存在チェック (gh api)
check_readme() {
  local repo="$1"
  if gh api "repos/${USERNAME}/${repo}/readme" &>/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
}

# ─── アーカイブ前スタンプ: description + README にアーカイブ理由を記録 ───
stamp_repo_before_archive() {
  local name="$1"
  local pushed_ago="$2"
  echo -e "  ${BOLD}Stamping ${name}...${NC}"

  # description にアーカイブ理由プレフィックスを付与
  if [[ "${ARCHIVE_UPDATE_DESC}" == "true" ]]; then
    local orig_desc="${REPO_DESC[$name]:-}"
    local new_desc
    if [[ -n "$orig_desc" ]]; then
      new_desc="${ARCHIVE_DESC_PREFIX} ${orig_desc}"
    else
      new_desc="${ARCHIVE_DESC_PREFIX} last pushed: ${pushed_ago}"
    fi
    # GitHub description は最大255文字
    new_desc="${new_desc:0:255}"
    if gh repo edit "${USERNAME}/${name}" --description "$new_desc" 2>/dev/null; then
      echo -e "    ${GREEN}✓ description updated${NC}"
    else
      echo -e "    ${YELLOW}✗ description update failed (skipped)${NC}"
    fi
  fi

  # README.md 先頭にアーカイブバナーを挿入
  if [[ "${ARCHIVE_UPDATE_README}" == "true" && "${REPO_HAS_README[$name]:-false}" == "true" ]]; then
    local readme_json readme_sha readme_path readme_content new_content encoded tmp_json

    readme_json="$(gh api "repos/${USERNAME}/${name}/readme" 2>/dev/null || echo "")"
    if [[ -z "$readme_json" ]]; then
      echo -e "    ${YELLOW}✗ README fetch failed (skipped)${NC}"
      return
    fi

    readme_sha="$(echo "$readme_json" | jq -r '.sha')"
    readme_path="$(echo "$readme_json" | jq -r '.path')"
    # base64 デコード（GitHub API は改行入り base64 を返すため改行を除去してからデコード）
    readme_content="$(echo "$readme_json" | jq -r '.content' | tr -d '\n' | base64 --decode)"

    new_content="> **[Archived]** このリポジトリは ${TODAY} に repo-health により自動アーカイブされました。
> 最終更新から ${ARCHIVE_MONTHS} ヶ月以上経過しているため、読み取り専用になっています。

---

${readme_content}"

    # base64 エンコード（改行なし、GNU/macOS 両対応）
    encoded="$(printf '%s' "$new_content" | base64 | tr -d '\n')"

    tmp_json="$(mktemp)"
    jq -n \
      --arg msg "chore: add archive notice to README [repo-health]" \
      --arg content "$encoded" \
      --arg sha "$readme_sha" \
      '{message: $msg, content: $content, sha: $sha}' > "$tmp_json"

    if gh api -X PUT "repos/${USERNAME}/${name}/contents/${readme_path}" \
        --input "$tmp_json" &>/dev/null; then
      echo -e "    ${GREEN}✓ README banner inserted${NC}"
    else
      echo -e "    ${YELLOW}✗ README update failed (skipped)${NC}"
    fi
    rm -f "$tmp_json"
  fi
}

echo -e "${BOLD}Analyzing repositories...${NC}"

for i in $(seq 0 $((TOTAL - 1))); do
  name="$(echo "${REPOS_JSON}" | jq -r ".[$i].name")"
  pushed_at="$(echo "${REPOS_JSON}" | jq -r ".[$i].pushedAt")"
  lang="$(echo "${REPOS_JSON}" | jq -r ".[${i}].primaryLanguage.name // \"—\"")"
  stars="$(echo "${REPOS_JSON}" | jq -r ".[$i].stargazerCount")"
  is_fork="$(echo "${REPOS_JSON}" | jq -r ".[$i].isFork")"
  desc="$(echo "${REPOS_JSON}" | jq -r ".[$i].description // \"\"")"
  is_archived="$(echo "${REPOS_JSON}" | jq -r ".[$i].isArchived")"

  # アーカイブ済み・フォークはスキップ
  [[ "$is_archived" == "true" ]] && continue
  [[ "$is_fork" == "true" ]] && continue

  REPO_PUSHED["$name"]="$pushed_at"
  REPO_LANG["$name"]="$lang"
  REPO_STARS["$name"]="$stars"
  REPO_IS_FORK["$name"]="$is_fork"
  REPO_DESC["$name"]="$desc"

  # pushed_at を epoch に変換
  if [[ -n "$pushed_at" && "$pushed_at" != "null" ]]; then
    if date --version &>/dev/null 2>&1; then
      pushed_epoch="$(date --date="$pushed_at" +%s 2>/dev/null || echo 0)"
    else
      pushed_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed_at" +%s 2>/dev/null || echo 0)"
    fi
  else
    pushed_epoch=0
  fi

  # always_active チェック
  if is_always_active "$name"; then
    ACTIVE_REPOS+=("$name")
    continue
  fi

  # 分類
  if [[ "$pushed_epoch" -ge "$STALE_EPOCH" ]]; then
    ACTIVE_REPOS+=("$name")
  elif [[ "$pushed_epoch" -ge "$ARCHIVE_EPOCH" ]]; then
    STALE_REPOS+=("$name")
  else
    ARCHIVE_REPOS+=("$name")
  fi
done

# README チェック (STALE + ARCHIVE のみ)
echo -e "Checking README existence for stale/archive repos..."
for name in "${STALE_REPOS[@]}" "${ARCHIVE_REPOS[@]}"; do
  REPO_HAS_README["$name"]="$(check_readme "$name")"
done
for name in "${ACTIVE_REPOS[@]}"; do
  REPO_HAS_README["$name"]="true"
done

# ─── 相対時刻フォーマット ───
format_pushed_ago() {
  local pushed_at="$1"
  if [[ -z "$pushed_at" || "$pushed_at" == "null" ]]; then
    echo "never"
    return
  fi

  if date --version &>/dev/null 2>&1; then
    pushed_epoch="$(date --date="$pushed_at" +%s 2>/dev/null || echo 0)"
  else
    pushed_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed_at" +%s 2>/dev/null || echo 0)"
  fi

  local diff=$(( NOW_EPOCH - pushed_epoch ))
  local days=$(( diff / 86400 ))

  if [[ $days -eq 0 ]]; then
    echo "today"
  elif [[ $days -eq 1 ]]; then
    echo "1 day ago"
  elif [[ $days -lt 7 ]]; then
    echo "${days} days ago"
  elif [[ $days -lt 14 ]]; then
    echo "1 week ago"
  elif [[ $days -lt 30 ]]; then
    echo "$(( days / 7 )) weeks ago"
  elif [[ $days -lt 60 ]]; then
    echo "1 month ago"
  elif [[ $days -lt 365 ]]; then
    echo "$(( days / 30 )) months ago"
  else
    echo "$(( days / 365 )) year(s) ago"
  fi
}

meta_icons() {
  local name="$1"
  local icons=""
  [[ -n "${REPO_DESC[$name]}" ]] && icons+=" ✓ desc" || icons+=" ✗ description なし"
  [[ "${REPO_HAS_README[$name]}" == "true" ]] && icons+=" ✓ readme" || icons+=" ✗ README なし"
  echo "$icons"
}

# ─── レポート生成 ───
TODAY="$(date +%Y-%m-%d)"
REPORT=""

REPORT+="=== GitHub Repository Audit: ${USERNAME} (${TODAY}) ===\n\n"

# ACTIVE
REPORT+="$(echo -e "${GREEN}${BOLD}🟢 ACTIVE (${#ACTIVE_REPOS[@]} repos)${NC}")\n"
for name in "${ACTIVE_REPOS[@]}"; do
  lang="${REPO_LANG[$name]:-—}"
  ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
  icons="$(meta_icons "$name")"
  REPORT+="  $(printf '%-35s' "$name") $(printf '%-15s' "$lang")  pushed: $(printf '%-20s' "$ago")${icons}\n"
done

REPORT+="\n"

# STALE
REPORT+="$(echo -e "${YELLOW}${BOLD}🟡 STALE (${#STALE_REPOS[@]} repos) — 放置気味${NC}")\n"
if [[ ${#STALE_REPOS[@]} -eq 0 ]]; then
  REPORT+="  (none)\n"
else
  for name in "${STALE_REPOS[@]}"; do
    lang="${REPO_LANG[$name]:-—}"
    ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
    icons="$(meta_icons "$name")"
    REPORT+="  $(printf '%-35s' "$name") $(printf '%-15s' "$lang")  pushed: $(printf '%-20s' "$ago")${icons}\n"
  done
fi

REPORT+="\n"

# ARCHIVE
REPORT+="$(echo -e "${RED}${BOLD}🔴 ARCHIVE CANDIDATES (${#ARCHIVE_REPOS[@]} repos)${NC}")\n"
if [[ ${#ARCHIVE_REPOS[@]} -eq 0 ]]; then
  REPORT+="  (none)\n"
else
  for name in "${ARCHIVE_REPOS[@]}"; do
    lang="${REPO_LANG[$name]:-—}"
    ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
    is_fork="${REPO_IS_FORK[$name]:-false}"
    stars="${REPO_STARS[$name]:-0}"
    icons="$(meta_icons "$name")"
    REPORT+="  $(printf '%-35s' "$name") $(printf '%-10s' "$lang")  pushed: $(printf '%-20s' "$ago")  fork:${is_fork} stars:${stars}${icons}\n"
  done
fi

# レポートを表示
echo -e "${REPORT}"

# ─── ファイルに保存 ───
save_report() {
  local dir="$1"
  mkdir -p "$dir"
  local file="${dir}/audit-${TODAY}.txt"
  # カラーコードなしで保存
  echo -e "${REPORT}" | sed 's/\x1b\[[0-9;]*m//g' > "$file"
  echo -e "${GREEN}Report saved: ${file}${NC}"
}

if [[ -n "${OUTPUT_DIR}" ]]; then
  save_report "${OUTPUT_DIR}"
fi

# --report-only の場合はここで終了
if [[ "${REPORT_ONLY}" == true ]]; then
  save_report "${REPORT_OUTPUT_DIR}"
  exit 0
fi

# ─── アクション選択 ───
if [[ "${CREATE_ISSUES}" == false && "${INTERACTIVE}" == false && "${FIX_META}" == false && "${AUTO_ARCHIVE}" == false ]]; then
  echo ""
  echo -e "${BOLD}Actions:${NC}"
  echo "  [1] レポートを ~/repo-health-reports/ に保存"
  echo "  [2] STALE リポジトリに GitHub Issue を作成"
  echo "  [3] ARCHIVE 候補を対話的にアーカイブ"
  echo "  [4] description/topics を一括編集モード"
  echo "  [q] 終了"
  echo ""
  read -r -p "選択 [1-4/q]: " choice
  case "$choice" in
    1) save_report "${REPORT_OUTPUT_DIR}" ;;
    2) CREATE_ISSUES=true ;;
    3) INTERACTIVE=true ;;
    4) FIX_META=true ;;
    q|Q|"") exit 0 ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi

# ─── Issue 作成（STALE + ARCHIVE） ───
if [[ "${CREATE_ISSUES}" == true ]]; then
  CREATED_STALE=()
  CREATED_ARCHIVE=()
  SKIPPED_REPOS=()

  # オープンな Health Check Issue が既存かチェックする共通処理
  has_open_issue() {
    local repo="$1"
    local count
    count="$(gh issue list \
      --repo "${USERNAME}/${repo}" \
      --state open \
      --search "Repository Health Check in:title" \
      --json number \
      --jq 'length' 2>/dev/null || echo 0)"
    [[ "${count}" -gt 0 ]]
  }

  # STALE リポジトリへの Issue 作成
  if [[ ${#STALE_REPOS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}--- Creating issues for STALE repositories ---${NC}"
    for name in "${STALE_REPOS[@]}"; do
      ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
      echo -n "  Creating issue for ${name}... "

      if has_open_issue "${name}"; then
        echo -e "${YELLOW}skipped (open issue already exists)${NC}"
        SKIPPED_REPOS+=("🟡 ${name} (${ago}) — open issue already exists")
        continue
      fi

      ISSUE_BODY="## Repository Health Check

**Last pushed:** ${ago}

このリポジトリはしばらく更新されていません。以下のいずれかのアクションを検討してください:

- [ ] 継続して開発する（README/description を更新）
- [ ] リポジトリをアーカイブする
- [ ] リポジトリを削除する

*このIssueは repo-health ツールによって自動作成されました。*"

      if err="$(gh issue create \
        --repo "${USERNAME}/${name}" \
        --title "🟡 Repository Health Check: 放置気味 (${ago})" \
        --body "${ISSUE_BODY}" 2>&1)"; then
        echo -e "${GREEN}done${NC}"
        CREATED_STALE+=("${name} (${ago})")
      else
        echo -e "${YELLOW}skipped (${err})${NC}"
        SKIPPED_REPOS+=("🟡 ${name} (${ago}) — ${err}")
      fi
    done
  fi

  # ARCHIVE リポジトリへの Issue 作成
  if [[ ${#ARCHIVE_REPOS[@]} -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}--- Creating issues for ARCHIVE candidate repositories ---${NC}"
    for name in "${ARCHIVE_REPOS[@]}"; do
      ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
      echo -n "  Creating issue for ${name}... "

      if has_open_issue "${name}"; then
        echo -e "${YELLOW}skipped (open issue already exists)${NC}"
        SKIPPED_REPOS+=("🔴 ${name} (${ago}) — open issue already exists")
        continue
      fi

      ISSUE_BODY="## Repository Health Check — Archive Candidate

**Last pushed:** ${ago}

このリポジトリは長期間更新されておらず、アーカイブ候補です。以下のいずれかのアクションを検討してください:

- [ ] リポジトリをアーカイブする（推奨）
- [ ] リポジトリを削除する
- [ ] 継続して開発する（README/description を更新）

*このIssueは repo-health ツールによって自動作成されました。*"

      if err="$(gh issue create \
        --repo "${USERNAME}/${name}" \
        --title "🔴 Repository Archive Candidate: 長期放置 (${ago})" \
        --body "${ISSUE_BODY}" 2>&1)"; then
        echo -e "${GREEN}done${NC}"
        CREATED_ARCHIVE+=("${name} (${ago})")
      else
        echo -e "${YELLOW}skipped (${err})${NC}"
        SKIPPED_REPOS+=("🔴 ${name} (${ago}) — ${err}")
      fi
    done
  fi

  # repo-health 自身にサマリー Issue を作成
  echo -e "\n  Creating summary issue in repo-health... "

  SUMMARY_BODY="## Audit Summary: ${TODAY}

### 🟡 STALE — Issue を作成 (${#CREATED_STALE[@]} 件)"
  if [[ ${#CREATED_STALE[@]} -gt 0 ]]; then
    for entry in "${CREATED_STALE[@]}"; do
      SUMMARY_BODY+="
- ${USERNAME}/${entry}"
    done
  else
    SUMMARY_BODY+="
(なし)"
  fi

  SUMMARY_BODY+="

### 🔴 ARCHIVE — Issue を作成 (${#CREATED_ARCHIVE[@]} 件)"
  if [[ ${#CREATED_ARCHIVE[@]} -gt 0 ]]; then
    for entry in "${CREATED_ARCHIVE[@]}"; do
      SUMMARY_BODY+="
- ${USERNAME}/${entry}"
    done
  else
    SUMMARY_BODY+="
(なし)"
  fi

  SUMMARY_BODY+="

### ⏭️ スキップ (${#SKIPPED_REPOS[@]} 件)"
  if [[ ${#SKIPPED_REPOS[@]} -gt 0 ]]; then
    for entry in "${SKIPPED_REPOS[@]}"; do
      SUMMARY_BODY+="
- ${USERNAME}/${entry}"
    done
  else
    SUMMARY_BODY+="
(なし)"
  fi

  SUMMARY_BODY+="

*このIssueは repo-health ツールによって自動作成されました。*"

  if err="$(gh issue create \
    --repo "${USERNAME}/repo-health" \
    --title "📋 Audit Report: ${TODAY} (🟡 ${#STALE_REPOS[@]} / 🔴 ${#ARCHIVE_REPOS[@]})" \
    --body "${SUMMARY_BODY}" 2>&1)"; then
    echo -e "${GREEN}done${NC}"
  else
    echo -e "${YELLOW}skipped (${err})${NC}"
  fi
fi

# ─── 対話的アーカイブ ───
if [[ "${INTERACTIVE}" == true ]]; then
  if [[ ${#ARCHIVE_REPOS[@]} -eq 0 ]]; then
    echo "No ARCHIVE candidates found."
  else
    echo -e "\n${RED}${BOLD}--- Interactive Archive Mode ---${NC}"
    echo "各リポジトリをアーカイブするか確認します。"
    echo ""

    for name in "${ARCHIVE_REPOS[@]}"; do
      ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
      lang="${REPO_LANG[$name]:-—}"
      desc="${REPO_DESC[$name]:-}"
      stars="${REPO_STARS[$name]:-0}"
      is_fork="${REPO_IS_FORK[$name]:-false}"

      echo -e "${BOLD}  ${name}${NC}"
      echo "    Language : ${lang}"
      echo "    Last push: ${ago}"
      echo "    Stars    : ${stars}  Fork: ${is_fork}"
      [[ -n "$desc" ]] && echo "    Desc     : ${desc}"
      echo ""

      read -r -p "  Archive ${USERNAME}/${name}? [y/N/q]: " ans
      case "$ans" in
        y|Y)
          echo -n "  Archiving... "
          gh repo archive "${USERNAME}/${name}" --yes
          echo -e "${GREEN}done${NC}"
          ;;
        q|Q)
          echo "Aborted."
          break
          ;;
        *)
          echo "  Skipped."
          ;;
      esac
      echo ""
    done
  fi
fi

# ─── description/topics 補完モード ───
if [[ "${FIX_META}" == true ]]; then
  echo -e "\n${BLUE}${BOLD}--- Meta Fix Mode (description/topics) ---${NC}"
  echo "description が空のリポジトリを順番に表示します。"
  echo ""

  for name in "${ACTIVE_REPOS[@]}" "${STALE_REPOS[@]}" "${ARCHIVE_REPOS[@]}"; do
    desc="${REPO_DESC[$name]:-}"
    [[ -n "$desc" ]] && continue

    lang="${REPO_LANG[$name]:-—}"
    ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"

    echo -e "${BOLD}  ${name}${NC} (${lang}, pushed: ${ago})"
    read -r -p "  Description を入力 (Enterでスキップ): " new_desc

    if [[ -n "$new_desc" ]]; then
      gh repo edit "${USERNAME}/${name}" --description "$new_desc"
      echo -e "  ${GREEN}Description updated.${NC}"
    fi

    read -r -p "  Topics を入力 (カンマ区切り、Enterでスキップ): " new_topics

    if [[ -n "$new_topics" ]]; then
      # カンマ区切りをスペース区切りに変換して --add-topic に渡す
      IFS=',' read -ra topic_arr <<< "$new_topics"
      topic_flags=()
      for t in "${topic_arr[@]}"; do
        trimmed="$(echo "$t" | tr -d ' ')"
        [[ -n "$trimmed" ]] && topic_flags+=("--add-topic" "$trimmed")
      done
      if [[ ${#topic_flags[@]} -gt 0 ]]; then
        gh repo edit "${USERNAME}/${name}" "${topic_flags[@]}"
        echo -e "  ${GREEN}Topics updated.${NC}"
      fi
    fi

    echo ""
  done

  echo -e "${GREEN}Meta fix complete.${NC}"
fi

# ─── 自動アーカイブ（CI向け・非対話型） ───
if [[ "${AUTO_ARCHIVE}" == true ]]; then
  if [[ ${#ARCHIVE_REPOS[@]} -eq 0 ]]; then
    echo -e "\n${GREEN}No ARCHIVE candidates found. Nothing to archive.${NC}"
  else
    echo -e "\n${RED}${BOLD}--- Auto Archive Mode (${#ARCHIVE_REPOS[@]} candidates) ---${NC}"
    echo "description と README にアーカイブ理由を記録してからアーカイブします。"

    ARCHIVED=()
    FAILED=()

    for name in "${ARCHIVE_REPOS[@]}"; do
      ago="$(format_pushed_ago "${REPO_PUSHED[$name]:-}")"
      echo ""
      echo -e "  ${BOLD}[${name}]${NC} — last pushed: ${ago}"

      # description / README にアーカイブ理由を記録
      stamp_repo_before_archive "$name" "$ago"

      # アーカイブ実行
      echo -n "    Archiving... "
      if gh repo archive "${USERNAME}/${name}" --yes 2>/dev/null; then
        echo -e "${GREEN}done${NC}"
        ARCHIVED+=("${name} (${ago})")
      else
        echo -e "${RED}failed${NC}"
        FAILED+=("${name}")
      fi
    done

    echo ""
    echo -e "${BOLD}Auto-archive complete: ${GREEN}${#ARCHIVED[@]} archived${NC}${BOLD}, ${RED}${#FAILED[@]} failed${NC}"

    # repo-health にサマリー Issue を作成
    ARCHIVE_SUMMARY_BODY="## Auto-Archive Report: ${TODAY}

### 🗄️ アーカイブ済み (${#ARCHIVED[@]} 件)"
    if [[ ${#ARCHIVED[@]} -gt 0 ]]; then
      for entry in "${ARCHIVED[@]}"; do
        ARCHIVE_SUMMARY_BODY+="
- ${USERNAME}/${entry}"
      done
    else
      ARCHIVE_SUMMARY_BODY+="
(なし)"
    fi

    if [[ ${#FAILED[@]} -gt 0 ]]; then
      ARCHIVE_SUMMARY_BODY+="

### ❌ 失敗 (${#FAILED[@]} 件)"
      for entry in "${FAILED[@]}"; do
        ARCHIVE_SUMMARY_BODY+="
- ${USERNAME}/${entry}"
      done
    fi

    ARCHIVE_SUMMARY_BODY+="

### 記録内容
- **description**: \`${ARCHIVE_DESC_PREFIX}\` プレフィックスを付与
- **README.md**: アーカイブ日時・理由のバナーを先頭に挿入

*このIssueは repo-health ツールによって自動作成されました。*"

    echo -e "\n  Creating summary issue in repo-health... "
    if err="$(gh issue create \
      --repo "${USERNAME}/repo-health" \
      --title "🗄️ Auto-Archive Report: ${TODAY} (${#ARCHIVED[@]} archived)" \
      --body "${ARCHIVE_SUMMARY_BODY}" 2>&1)"; then
      echo -e "${GREEN}done${NC}"
    else
      echo -e "${YELLOW}skipped (${err})${NC}"
    fi
  fi
fi
