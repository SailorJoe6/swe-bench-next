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
#   ./scripts/view-traj.sh <path-to-traj-file>           # View last 3 steps
#   ./scripts/view-traj.sh <path-to-traj-file> --tail   # Tail mode (updates every 2s)
#   ./scripts/view-traj.sh <path-to-traj-file> --all    # Show entire trajectory
#
# Examples:
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj --tail

set -euo pipefail

TRAJ_FILE="${1:-}"
MODE="${2:-last}"

# Number of steps to show (chosen to fit ~50-60 lines of output per step)
SHOW_STEPS=3

if [[ -z "$TRAJ_FILE" ]]; then
    echo "Usage: $0 <traj-file> [--tail|--all]"
    echo ""
    echo "Examples:"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj --tail"
    echo "  $0 results/phase3/full-run/instance-id/instance-id.traj --all"
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
read -r -d '' JQ_FILTER <<'EOF' || true
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
EOF

# Function to display trajectory
display_traj() {
    local slice_filter="$1"
    clear
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;37m📊 SWE-Agent Trajectory Viewer\033[0m"
    echo -e "\033[0;90mFile: $TRAJ_FILE\033[0m"

    # Get total steps
    local total_steps=$(jq -r '.trajectory | length' "$TRAJ_FILE" 2>/dev/null || echo "0")

    if [[ "$MODE" == "tail" ]]; then
        echo -e "\033[0;90mMode: TAIL (updating every 2s) | Total steps: $total_steps | Showing: last $SHOW_STEPS\033[0m"
    elif [[ "$MODE" == "all" ]]; then
        echo -e "\033[0;90mMode: FULL | Total steps: $total_steps\033[0m"
    else
        echo -e "\033[0;90mMode: LAST | Total steps: $total_steps | Showing: last $SHOW_STEPS\033[0m"
    fi

    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    # Build the full JQ program
    local full_filter="$slice_filter | {trajectory: .} | $JQ_FILTER"
    jq -r "$full_filter" "$TRAJ_FILE" 2>/dev/null || echo -e "\n\033[0;31mError: Could not parse trajectory file\033[0m\n"
}

# Execute based on mode
case "$MODE" in
    --tail)
        MODE="tail"
        echo "🔄 Starting tail mode (Ctrl+C to stop)..."
        sleep 1
        while true; do
            display_traj ".trajectory | .[-${SHOW_STEPS}:]"
            sleep 2
        done
        ;;
    --all)
        MODE="all"
        display_traj "."
        ;;
    *)
        MODE="last"
        display_traj ".trajectory | .[-${SHOW_STEPS}:]"
        ;;
esac
