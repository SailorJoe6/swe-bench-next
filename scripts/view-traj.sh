#!/bin/bash
#
# View SWE-agent trajectory files with formatted, colorized output
#
# Trajectory files contain the full agent execution history including:
#   - Actions (commands/tools executed)
#   - Thoughts (agent reasoning)
#   - Responses (agent messages)
#   - Observations (command outputs)
#
# Usage:
#   ./scripts/view-traj.sh <path-to-traj-file>           # View entire trajectory
#   ./scripts/view-traj.sh <path-to-traj-file> -f       # Tail mode (like tail -f)
#   ./scripts/view-traj.sh <path-to-traj-file> -n N     # Show last N steps
#
# Examples:
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj -f
#   ./scripts/view-traj.sh results/phase3/full-run/apache__druid-13704/apache__druid-13704.traj -n 5

set -euo pipefail

TRAJ_FILE=""
MODE="all"
N_STEPS=10

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--follow)
            MODE="follow"
            shift
            ;;
        -n|--last)
            MODE="last"
            N_STEPS="${2:-10}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <traj-file> [-f|--follow] [-n|--last N]"
            echo ""
            echo "Options:"
            echo "  -f, --follow     Follow mode (like tail -f)"
            echo "  -n, --last N     Show last N steps"
            echo ""
            echo "Examples:"
            echo "  $0 results/phase3/full-run/instance-id/instance-id.traj"
            echo "  $0 results/phase3/full-run/instance-id/instance-id.traj -f"
            echo "  $0 results/phase3/full-run/instance-id/instance-id.traj -n 5"
            exit 0
            ;;
        *)
            if [[ -z "$TRAJ_FILE" ]]; then
                TRAJ_FILE="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$TRAJ_FILE" ]]; then
    echo "Usage: $0 <traj-file> [-f|--follow] [-n|--last N]"
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
.[] |
(
  "\n" + cyan + bold + "═══════════════════════════════════════════════════════════════════════════" + reset + "\n" +
  cyan + bold + "STEP \(.step_num)" + reset +
  gray + " | " + reset +
  yellow + "\(.execution_time | tonumber | . * 1000 | floor / 1000)s" + reset +
  "\n" +
  cyan + bold + "═══════════════════════════════════════════════════════════════════════════" + reset + "\n\n" +

  # Action
  (if .action != "" then
    blue + bold + "🔧 ACTION:" + reset + "\n" +
    "   " + (.action | truncate(200)) + "\n\n"
  else "" end) +

  # Thought (agent reasoning)
  (if .thought != "" then
    magenta + bold + "💭 THOUGHT:" + reset + "\n" +
    (.thought | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # Response (agent message to user)
  (if .response != "" then
    green + bold + "💬 RESPONSE:" + reset + "\n" +
    (.response | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # Observation (command output) - truncated
  (if .observation != "" then
    yellow + bold + "👁️  OBSERVATION:" + reset +
    gray + " (truncated to 500 chars)" + reset + "\n" +
    (.observation | truncate(500) | split("\n") | map("   " + .) | join("\n")) + "\n\n"
  else "" end) +

  # Working directory
  gray + "📁 Working dir: " + .state.working_dir + reset
)
EOF

# Function to format steps
format_steps() {
    local start_idx="$1"
    local end_idx="$2"

    jq -r ".trajectory[$start_idx:$end_idx] | to_entries | map(.value + {step_num: (.key + $start_idx + 1)}) | $JQ_FILTER" "$TRAJ_FILE" 2>/dev/null
}

# Execute based on mode
case "$MODE" in
    follow)
        echo "📡 Following trajectory (Ctrl+C to stop)..."
        echo "File: $TRAJ_FILE"
        echo ""

        # Track how many steps we've seen
        LAST_STEP_COUNT=0

        while true; do
            # Get current step count
            CURRENT_STEP_COUNT=$(jq -r '.trajectory | length' "$TRAJ_FILE" 2>/dev/null || echo "0")

            # If there are new steps, display them
            if [[ $CURRENT_STEP_COUNT -gt $LAST_STEP_COUNT ]]; then
                format_steps "$LAST_STEP_COUNT" "$CURRENT_STEP_COUNT"
                LAST_STEP_COUNT=$CURRENT_STEP_COUNT
            fi

            # Wait 2 seconds before checking again
            sleep 2
        done
        ;;
    last)
        TOTAL_STEPS=$(jq -r '.trajectory | length' "$TRAJ_FILE" 2>/dev/null || echo "0")
        START_IDX=$((TOTAL_STEPS - N_STEPS))
        if [[ $START_IDX -lt 0 ]]; then
            START_IDX=0
        fi
        format_steps "$START_IDX" "$TOTAL_STEPS"
        ;;
    *)
        # Show all steps
        TOTAL_STEPS=$(jq -r '.trajectory | length' "$TRAJ_FILE" 2>/dev/null || echo "0")
        format_steps "0" "$TOTAL_STEPS"
        ;;
esac
