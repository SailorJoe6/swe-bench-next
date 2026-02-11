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
TOTAL_INSTANCES=299  # Total instances to evaluate

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

# Check if sweagent is running
if pgrep -f "sweagent run-batch" > /dev/null; then
    RUNNING_STATUS="${GREEN}✓ RUNNING${NC}"
    RUNNING_PID=$(pgrep -f "sweagent run-batch")
else
    RUNNING_STATUS="${RED}✗ NOT RUNNING${NC}"
    RUNNING_PID="N/A"
fi

# Count completed instances
COMPLETED=$(find "$EVAL_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
COMPLETED=$((COMPLETED))  # Remove leading spaces

# Calculate progress percentage
if [ "$COMPLETED" -gt 0 ]; then
    PROGRESS_PCT=$(echo "scale=1; ($COMPLETED * 100) / $TOTAL_INSTANCES" | bc)
else
    PROGRESS_PCT="0.0"
fi

# Read exit statuses if available
if [ -f "$EVAL_DIR/run_batch_exit_statuses.yaml" ]; then
    SUBMITTED=$(grep -A 500 "submitted:" "$EVAL_DIR/run_batch_exit_statuses.yaml" | grep "^    -" | grep -v "exit_error" | wc -l || echo "0")
    EXIT_ERROR=$(grep -A 500 "submitted (exit_error):" "$EVAL_DIR/run_batch_exit_statuses.yaml" | grep "^    -" | wc -l || echo "0")
else
    SUBMITTED="N/A"
    EXIT_ERROR="N/A"
fi

# Get last completed instance
if [ -d "$EVAL_DIR" ]; then
    LAST_COMPLETED=$(ls -t "$EVAL_DIR" | grep -v "\.log$\|\.yaml$" | head -1)
    if [ -n "$LAST_COMPLETED" ]; then
        LAST_COMPLETED_TIME=$(stat -c %y "$EVAL_DIR/$LAST_COMPLETED" 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
    else
        LAST_COMPLETED="N/A"
        LAST_COMPLETED_TIME="N/A"
    fi
else
    LAST_COMPLETED="N/A"
    LAST_COMPLETED_TIME="N/A"
fi

# Get currently processing instance from log
if [ -f "$EVAL_DIR/run_batch.log" ]; then
    CURRENT=$(tail -1000 "$EVAL_DIR/run_batch.log" | grep "Running on instance" | tail -1 | sed 's/.*Running on instance //' || echo "Unknown")
    CURRENT_TIME=$(tail -1000 "$EVAL_DIR/run_batch.log" | grep "Running on instance" | tail -1 | cut -d' ' -f1-2 || echo "Unknown")
else
    CURRENT="N/A"
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
echo -e "${BOLD}Successful:${NC}       ${GREEN}$SUBMITTED patches submitted${NC}"
echo -e "${BOLD}Errors:${NC}           ${RED}$EXIT_ERROR exit errors${NC}"
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

# Show recent log activity
if [ -f "$EVAL_DIR/run_batch.log" ]; then
    echo
    echo -e "${BOLD}${BLUE}Recent Activity:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    tail -100 "$EVAL_DIR/run_batch.log" | grep -E "(INFO|ERROR|WARNING)" | tail -5 || echo "  (no recent log entries)"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
fi

echo
