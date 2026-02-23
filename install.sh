#!/bin/bash
set -e

# ─────────────────────────────────────────────
# repo-health: インストールスクリプト
# LaunchAgent 登録 + セットアップ
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.user.repo-health"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
REPORT_DIR="${HOME}/repo-health-reports"
LOG_DIR="${REPORT_DIR}/logs"

echo "🔍 Installing repo-health..."
echo ""

# macOS チェック
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo -e "${RED}Error: This tool is designed for macOS only.${NC}"
  exit 1
fi

# 依存チェック
for cmd in gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: ${cmd} is required.${NC}"
    [[ "$cmd" == "gh" ]] && echo "  Install: brew install gh && gh auth login"
    [[ "$cmd" == "jq" ]] && echo "  Install: brew install jq"
    exit 1
  fi
done

echo -e "${GREEN}✓${NC} Dependencies found (gh, jq)"

# gh 認証チェック
if ! gh auth status &>/dev/null; then
  echo -e "${RED}Error: gh CLI is not authenticated.${NC}"
  echo "  Run: gh auth login"
  exit 1
fi

echo -e "${GREEN}✓${NC} gh CLI authenticated"

# 実行権限付与
chmod +x "${SCRIPT_DIR}/repo-audit.sh"
echo -e "${GREEN}✓${NC} repo-audit.sh is executable"

# レポートディレクトリ作成
mkdir -p "${REPORT_DIR}" "${LOG_DIR}"
echo -e "${GREEN}✓${NC} Report directory: ${REPORT_DIR}"

# LaunchAgent インストール確認
echo ""
read -r -p "Install LaunchAgent for monthly audit? (y/N): " -n 1
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "🤖 Installing LaunchAgent..."

  mkdir -p "${HOME}/Library/LaunchAgents"

  cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/repo-audit.sh</string>
    <string>--report-only</string>
    <string>--output</string>
    <string>${REPORT_DIR}</string>
  </array>

  <!-- 毎月1日 09:00 に実行 -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Day</key>
    <integer>1</integer>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/repo-audit.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/repo-audit-error.log</string>

  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF

  # 既存のエージェントをアンロードしてから再ロード
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
  launchctl load "${PLIST_PATH}"

  echo -e "${GREEN}✓${NC} LaunchAgent installed: ${PLIST_PATH}"
  echo "   The audit will run on the 1st of every month at 9:00 AM."
else
  echo "Skipped LaunchAgent installation."
fi

# 動作確認の案内
echo ""
echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo "Usage:"
echo "  ./repo-audit.sh                    # レポートを表示して操作"
echo "  ./repo-audit.sh --report-only      # レポートのみ表示"
echo "  ./repo-audit.sh --interactive      # 対話的にアーカイブ"
echo "  ./repo-audit.sh --fix-meta         # description/topics 補完"
echo "  ./repo-audit.sh --create-issues    # STALE に Issue を自動作成"
echo ""
echo "Reports: ${REPORT_DIR}"
echo "Logs   : ${LOG_DIR}"
echo ""
echo -e "${YELLOW}Tip:${NC} 今すぐ試すには: ${SCRIPT_DIR}/repo-audit.sh --report-only"
