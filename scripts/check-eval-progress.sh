#!/usr/bin/env bash
#
# check-eval-progress.sh - Monitor SWE-agent evaluation progress
#
# Usage:
#   ./scripts/check-eval-progress.sh [eval-dir]
#
# Default eval-dir: results/phase3/full-run

set -euo pipefail

# Configuration
EVAL_DIR="${1:-results/phase3/full-run}"
START_TIME="2026-02-10 21:10"  # When the evaluation started
CONFIGURED_TOTAL_INSTANCES=299  # Expected total instances to evaluate

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}   SWE-Agent Evaluation Progress Monitor${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo

# Check if evaluation directory exists
if [ ! -d "$EVAL_DIR" ]; then
    echo -e "${RED}Error: Evaluation directory not found: $EVAL_DIR${NC}"
    exit 1
fi

# Build reusable instance lists
TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ALL_INSTANCES_FILE="$TMP_DIR/all_instances.txt"
ATTEMPTED_FILE="$TMP_DIR/attempted.txt"
FAILED_FILE="$TMP_DIR/failed.txt"
TRAJ_FILE="$TMP_DIR/trajectory_saved.txt"
COMPLETED_FILE="$TMP_DIR/completed.txt"
FAILED_NO_TRAJ_FILE="$TMP_DIR/failed_no_trajectory.txt"
NOT_ATTEMPTED_FILE="$TMP_DIR/not_attempted.txt"
IN_PROGRESS_FILE="$TMP_DIR/in_progress.txt"
EXIT_ERROR_FILE="$TMP_DIR/exit_error.txt"

find "$EVAL_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -u > "$ALL_INSTANCES_FILE"
DISCOVERED_TOTAL=$(wc -l < "$ALL_INSTANCES_FILE")

# Check if sweagent is running (avoid race between check and pid lookup)
RUNNING_PIDS=$(pgrep -f "sweagent run-batch" || true)
if [ -n "$RUNNING_PIDS" ]; then
    IS_RUNNING=1
    RUNNING_STATUS="${GREEN}✓ RUNNING${NC}"
    RUNNING_PID=$(echo "$RUNNING_PIDS" | paste -sd "," -)
else
    IS_RUNNING=0
    RUNNING_STATUS="${RED}✗ NOT RUNNING${NC}"
    RUNNING_PID="N/A"
fi

# Attempted and failed sets from batch log
if [ -f "$EVAL_DIR/run_batch.log" ]; then
    grep "Running on instance " "$EVAL_DIR/run_batch.log" | sed 's/.*Running on instance //' | sort -u > "$ATTEMPTED_FILE" || true
    grep "❌ Failed on " "$EVAL_DIR/run_batch.log" | sed 's/.*❌ Failed on \([^:]*\):.*/\1/' | sort -u > "$FAILED_FILE" || true
else
    : > "$ATTEMPTED_FILE"
    : > "$FAILED_FILE"
fi

# Trajectory-saved set from per-instance logs
grep -l "Trajectory saved" "$EVAL_DIR"/*/*.info.log 2>/dev/null \
    | sed -E 's#^.*/([^/]+)/[^/]+\.info\.log$#\1#' \
    | sort -u > "$TRAJ_FILE" || true

# Exit error set (subset of trajectory-saved instances)
: > "$EXIT_ERROR_FILE"
for d in "$EVAL_DIR"/*/; do
    [ -d "$d" ] || continue
    instance_dir=$(basename "$d")
    info_log="$d/${instance_dir}.info.log"
    if [ -f "$info_log" ] && grep -q "Trajectory saved" "$info_log" 2>/dev/null && grep -q "Exit due to unknown error" "$info_log" 2>/dev/null; then
        echo "$instance_dir" >> "$EXIT_ERROR_FILE"
    fi
done
sort -u -o "$EXIT_ERROR_FILE" "$EXIT_ERROR_FILE"

# Completed = instances with trajectory OR terminal batch failure
cat "$TRAJ_FILE" "$FAILED_FILE" | sort -u > "$COMPLETED_FILE"
comm -23 "$FAILED_FILE" "$TRAJ_FILE" > "$FAILED_NO_TRAJ_FILE" || true

if [ -s "$ATTEMPTED_FILE" ]; then
    comm -23 "$ALL_INSTANCES_FILE" "$ATTEMPTED_FILE" > "$NOT_ATTEMPTED_FILE" || true
    comm -23 "$ATTEMPTED_FILE" "$COMPLETED_FILE" > "$IN_PROGRESS_FILE" || true
else
    cp "$ALL_INSTANCES_FILE" "$NOT_ATTEMPTED_FILE"
    : > "$IN_PROGRESS_FILE"
fi

ATTEMPTED=$(wc -l < "$ATTEMPTED_FILE")
FAILED_COUNT=$(wc -l < "$FAILED_FILE")
SUBMITTED=$(wc -l < "$TRAJ_FILE")
EXIT_ERROR=$(wc -l < "$EXIT_ERROR_FILE")
FAILED_NO_TRAJECTORY=$(wc -l < "$FAILED_NO_TRAJ_FILE")
NOT_ATTEMPTED=$(wc -l < "$NOT_ATTEMPTED_FILE")
IN_PROGRESS=$(wc -l < "$IN_PROGRESS_FILE")
COMPLETED=$(wc -l < "$COMPLETED_FILE")
PREDICTIONS=$(find "$EVAL_DIR" -mindepth 2 -maxdepth 2 -name "*.pred" | wc -l)

TOTAL_INSTANCES="$DISCOVERED_TOTAL"
if [ "$TOTAL_INSTANCES" -eq 0 ]; then
    TOTAL_INSTANCES="$CONFIGURED_TOTAL_INSTANCES"
fi

# Calculate progress percentage from finalized completed count
if [ "$TOTAL_INSTANCES" -gt 0 ]; then
    PROGRESS_PCT=$(echo "scale=1; ($COMPLETED * 100) / $TOTAL_INSTANCES" | bc)
else
    PROGRESS_PCT="0.0"
fi

# Last completed instance = newest info log with explicit "Trajectory saved"
LAST_COMPLETED="N/A"
LAST_COMPLETED_TIME="N/A"
last_saved_info=""
for info_log in "$EVAL_DIR"/*/*.info.log; do
    [ -f "$info_log" ] || continue
    if grep -q "Trajectory saved" "$info_log" 2>/dev/null; then
        if [ -z "$last_saved_info" ] || [ "$info_log" -nt "$last_saved_info" ]; then
            last_saved_info="$info_log"
        fi
    fi
done
if [ -n "$last_saved_info" ]; then
    LAST_COMPLETED=$(basename "$(dirname "$last_saved_info")")
    LAST_COMPLETED_TIME=$(stat -c %y "$last_saved_info" 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
fi

# Get currently processing instance from log (only if run is active)
if [ "$IS_RUNNING" -eq 1 ] && [ -f "$EVAL_DIR/run_batch.log" ]; then
    CURRENT=$(tail -1000 "$EVAL_DIR/run_batch.log" | grep "Running on instance" | tail -1 | sed 's/.*Running on instance //' || echo "Unknown")
    CURRENT_TIME=$(tail -1000 "$EVAL_DIR/run_batch.log" | grep "Running on instance" | tail -1 | cut -d' ' -f1-2 || echo "Unknown")
else
    CURRENT="N/A (not running)"
    CURRENT_TIME="N/A"
fi

# Calculate time elapsed and remaining
START_EPOCH=$(date -d "$START_TIME" +%s 2>/dev/null || echo "0")
NOW_EPOCH=$(date +%s)
ELAPSED_SECONDS=$((NOW_EPOCH - START_EPOCH))
ELAPSED_HOURS=$(echo "scale=1; $ELAPSED_SECONDS / 3600" | bc)

if [ "$COMPLETED" -gt 0 ]; then
    AVG_TIME_PER_INSTANCE=$(echo "scale=1; $ELAPSED_SECONDS / $COMPLETED" | bc)
    REMAINING_INSTANCES=$((TOTAL_INSTANCES - COMPLETED))
    if [ "$REMAINING_INSTANCES" -lt 0 ]; then
        REMAINING_INSTANCES=0
    fi
    REMAINING_SECONDS=$(echo "scale=0; $AVG_TIME_PER_INSTANCE * $REMAINING_INSTANCES / 1" | bc)
    REMAINING_HOURS=$(echo "scale=1; $REMAINING_SECONDS / 3600" | bc)
    EST_COMPLETION=$(date -d "@$((NOW_EPOCH + ${REMAINING_SECONDS%.*}))" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")
else
    AVG_TIME_PER_INSTANCE="N/A"
    REMAINING_HOURS="N/A"
    EST_COMPLETION="N/A"
fi

# Display status
echo -e "${BOLD}Status:${NC}           $RUNNING_STATUS (PID: $RUNNING_PID)"
echo -e "${BOLD}Progress:${NC}         $COMPLETED / $TOTAL_INSTANCES instances (${PROGRESS_PCT}%)"
if [ "$DISCOVERED_TOTAL" -ne "$CONFIGURED_TOTAL_INSTANCES" ]; then
    echo -e "${BOLD}Scope:${NC}            ${YELLOW}$DISCOVERED_TOTAL discovered in output dir${NC} (configured target: $CONFIGURED_TOTAL_INSTANCES)"
fi
echo -e "${BOLD}Attempted:${NC}        $ATTEMPTED"
echo -e "${BOLD}Predictions:${NC}      ${GREEN}$PREDICTIONS patches generated${NC}"
echo -e "${BOLD}Trajectories:${NC}     ${BLUE}$SUBMITTED saved${NC}"
echo -e "${BOLD}Failures:${NC}         ${RED}$FAILED_COUNT total${NC} (${FAILED_NO_TRAJECTORY} without trajectory)"
echo -e "${BOLD}Exit Errors:${NC}      ${RED}$EXIT_ERROR with autosubmission${NC}"
echo -e "${BOLD}Not Attempted:${NC}    $NOT_ATTEMPTED"
echo -e "${BOLD}In Progress:${NC}      $IN_PROGRESS"

# Add evaluation stats if JSON exists
EVAL_JSON="$EVAL_DIR.eval-batch.json"
if [ -f "$EVAL_JSON" ]; then
    RESOLVED=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('resolved_instances', 0))" 2>/dev/null || echo "0")
    UNRESOLVED=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('unresolved_instances', 0))" 2>/dev/null || echo "0")
    EMPTY=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('empty_patch_instances', 0))" 2>/dev/null || echo "0")
    EVALUATED=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('completed_instances', 0))" 2>/dev/null || echo "0")
    
    if [ "$EVALUATED" -gt 0 ]; then
        PASS_RATE="${RESOLVED}/${EVALUATED} ($((RESOLVED * 100 / EVALUATED))%)"
    else
        PASS_RATE="N/A"
    fi
    echo
    echo -e "${BOLD}Evaluation:${NC}       ${BLUE}$EVALUATED patches evaluated${NC}"
    echo -e "${BOLD}  Resolved:${NC}         ${GREEN}$RESOLVED${NC}"
    echo -e "${BOLD}  Unresolved:${NC}       ${RED}$UNRESOLVED${NC}"
    echo -e "${BOLD}  Empty:${NC}            ${YELLOW}$EMPTY${NC}"
    echo -e "${BOLD}  Pass Rate:${NC}        ${CYAN}$PASS_RATE${NC}"
fi
echo
echo -e "${BOLD}${BLUE}Last Completed:${NC}"
echo -e "  Instance: $LAST_COMPLETED"
echo -e "  Time:     $LAST_COMPLETED_TIME"
echo
echo -e "${BOLD}${YELLOW}Currently Processing:${NC}"
echo -e "  Instance: $CURRENT"
echo -e "  Started:  $CURRENT_TIME"
echo
echo -e "${BOLD}${CYAN}Timing:${NC}"
echo -e "  Started:            $START_TIME"
echo -e "  Elapsed:            ${ELAPSED_HOURS} hours"
echo -e "  Avg per instance:   $(echo "scale=1; $AVG_TIME_PER_INSTANCE / 60" | bc 2>/dev/null || echo "N/A") minutes"
echo -e "  Est. remaining:     ${REMAINING_HOURS} hours"
echo -e "  Est. completion:    $EST_COMPLETION"
echo
echo -e "${BOLD}Output Directory:${NC} $EVAL_DIR"
echo
