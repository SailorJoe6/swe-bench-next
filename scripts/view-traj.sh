#!/bin/bash
#
# View SWE-agent trajectory files with formatted, colorized output
#
# Trajectory files contain the full agent execution history including:
#   - Actions (commands/tools executed)
#   - Thoughts (agent reasoning)
#   - Responses (agent messages)
#   - Observations (command outputs)
#   - Diffs (code changes)
#
# Usage:
#   ./scripts/view-traj.sh <path-to-traj-file>           # View entire trajectory
#   ./scripts/view-traj.sh <path-to-traj-file> --tail   # Tail trajectory (follow mode)
#   ./scripts/view-traj.sh <path-to-traj-file> --last N # Show last N steps
#
# Examples:
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj --last 5
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj --tail

set -euo pipefail

TRAJ_FILE="${1:-}"
MODE="${2:-full}"
LINES="${3:-10}"

if [[ -z "$TRAJ_FILE" ]]; then
    echo "Usage: $0 <traj-file> [--tail|--last N]"
    echo ""
    echo "Examples:"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj --tail"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj --last 5"
    exit 1
fi

# Make path relative to repo root if not absolute
if [[ ! "$TRAJ_FILE" = /* ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    TRAJ_FILE="$REPO_ROOT/$TRAJ_FILE"
fi

if [[ ! -f "$TRAJ_FILE" ]]; then
    echo "Error: File not found: $TRAJ_FILE"
    exit 1
fi

# JQ filter for pretty formatting
JQ_FILTER='
# Color codes
def red: "\u001b[31m";
def green: "\u001b[32m";
def yellow: "\u001b[33m";
def blue: "\u001b[34m";
def magenta: "\u001b[35m";
def cyan: "\u001b[36m";
def gray: "\u001b[90m";
def bold: "\u001b[1m";
def reset: "\u001b[0m";

# Truncate long strings
def truncate(n): if length > n then .[:n] + "..." else . end;

# Format each step
.trajectory | to_entries | .[] |
(
  "\n" + cyan + bold + "═══════════════════════════════════════════════════════════════════════════" + reset + "\n" +
  cyan + bold + "STEP \(.key + 1)" + reset +
  gray + " | " + reset +
  yellow + "\(.value.execution_time | tonumber | . * 1000 | floor / 1000)s" + reset +
  "\n" +
  cyan + bold + "═══════════════════════════════════════════════════════════════════════════" + reset + "\n\n" +

  # Action
  (if .value.action != "" then
    blue + bold + "🔧 ACTION:" + reset + "\n" +
    "   " + (.value.action | truncate(200)) + "\n\n"
  else "" end) +

  # Thought (agent reasoning)
  (if .value.thought != "" then
    magenta + bold + "💭 THOUGHT:" + reset + "\n" +
    (.value.thought | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # Response (agent message to user)
  (if .value.response != "" then
    green + bold + "💬 RESPONSE:" + reset + "\n" +
    (.value.response | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # Observation (command output) - truncated
  (if .value.observation != "" then
    yellow + bold + "👁️  OBSERVATION:" + reset +
    gray + " (truncated to 500 chars)" + reset + "\n" +
    (.value.observation | truncate(500) | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # State changes
  (if .value.state.diff != "" then
    red + bold + "📝 DIFF:" + reset + "\n" +
    (.value.state.diff | split("\n") | .[0:20] | map("   " + .) | join("\n")) +
    (if (.value.state.diff | split("\n") | length) > 20 then
      "\n   " + gray + "... (diff truncated)" + reset
    else "" end) + "\n\n"
  else "" end) +

  # Working directory
  gray + "📁 Working dir: " + .value.state.working_dir + reset
)
'

# Execute based on mode
case "$MODE" in
    --tail)
        echo "📡 Tailing trajectory file (Ctrl+C to stop)..."
        echo "File: $TRAJ_FILE"
        tail -f "$TRAJ_FILE" | jq -r --unbuffered "$JQ_FILTER"
        ;;
    --last)
        LAST_N="${LINES:-10}"
        jq -r ".trajectory | .[-${LAST_N}:] | {trajectory: .} | $JQ_FILTER" "$TRAJ_FILE"
        ;;
    *)
        jq -r "$JQ_FILTER" "$TRAJ_FILE"
        ;;
esac
