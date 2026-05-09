#!/bin/bash
# Server-only launcher for fair single-vs-multiprocess benchmark.
# Features:
#   1) Large default scale: total PE = 256x256
#   2) Chip partitions: 1 / 4 / 16 chips (fixed total PE)
#   3) Repeats default = 10
#   4) Detached background run via nohup (survives SSH disconnect)
#
# Subcommands:
#   start   (default) start a detached job
#   status  show whether the latest launched job is still running
#   tail    tail latest launcher log
#   stop    stop latest launched job (SIGTERM)
#
# Examples:
#   bash scripts/run_server_single_vs_multiprocess_256.sh
#   bash scripts/run_server_single_vs_multiprocess_256.sh start --sim 8000 --repeats 6
#   bash scripts/run_server_single_vs_multiprocess_256.sh status
#   bash scripts/run_server_single_vs_multiprocess_256.sh tail
#   bash scripts/run_server_single_vs_multiprocess_256.sh stop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- default experiment parameters ----------
SIM=12000
REPEATS=10
TIMESTEPS=5
INTERVAL=2000
SPARSITIES="0.05,0.15,0.30"
CHIP_CONFIGS="1:256:256,4:128:128,16:64:64"

# Optional larger chip count (disabled by default):
# CHIP_CONFIGS="1:256:256,4:128:128,16:64:64,64:32:32"

# ---------------- job bookkeeping ----------------
JOB_DIR="$ROOT_DIR/results/server_jobs"
mkdir -p "$JOB_DIR"
LATEST_META="$JOB_DIR/single_vs_multi_256_latest.env"

ACTION="start"
if [[ $# -gt 0 ]]; then
  case "$1" in
    start|status|tail|stop)
      ACTION="$1"
      shift
      ;;
  esac
fi

usage() {
  cat <<'USAGE'
Usage:
  run_server_single_vs_multiprocess_256.sh [start|status|tail|stop] [options]

start options:
  --sim N
  --repeats N
  --timesteps N
  --interval N
  --sparsities "a,b,c"
  --chip-configs "c:x:y,..."

Examples:
  bash scripts/run_server_single_vs_multiprocess_256.sh
  bash scripts/run_server_single_vs_multiprocess_256.sh start --sim 8000 --repeats 6
  bash scripts/run_server_single_vs_multiprocess_256.sh status
USAGE
}

load_latest_meta() {
  if [[ ! -f "$LATEST_META" ]]; then
    echo "No previous job metadata found: $LATEST_META"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$LATEST_META"
  return 0
}

case "$ACTION" in
  status)
    if ! load_latest_meta; then
      exit 1
    fi
    if kill -0 "$PID" 2>/dev/null; then
      echo "RUNNING"
      echo "job_id    : $JOB_ID"
      echo "pid       : $PID"
      echo "log       : $LAUNCH_LOG"
      echo "started   : $START_TIME"
    else
      echo "NOT RUNNING"
      echo "job_id    : $JOB_ID"
      echo "pid       : $PID"
      echo "log       : $LAUNCH_LOG"
      echo "started   : $START_TIME"
    fi
    exit 0
    ;;
  tail)
    if ! load_latest_meta; then
      exit 1
    fi
    [[ -f "$LAUNCH_LOG" ]] || { echo "Log not found: $LAUNCH_LOG"; exit 1; }
    echo "Tailing: $LAUNCH_LOG"
    tail -n 200 -f "$LAUNCH_LOG"
    ;;
  stop)
    if ! load_latest_meta; then
      exit 1
    fi
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      echo "Sent SIGTERM to PID $PID (job_id=$JOB_ID)"
    else
      echo "Process already not running (PID $PID)."
    fi
    exit 0
    ;;
  start)
    ;;
  *)
    usage
    exit 1
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) SIM="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --timesteps) TIMESTEPS="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --sparsities) SPARSITIES="$2"; shift 2 ;;
    --chip-configs) CHIP_CONFIGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

JOB_ID="single_vs_multi_256_$(date +%Y%m%d_%H%M%S)"
LAUNCH_LOG="$JOB_DIR/${JOB_ID}.log"
CMD_FILE="$JOB_DIR/${JOB_ID}.cmd.sh"

cat > "$CMD_FILE" <<EOF
#!/bin/bash
set -euo pipefail
cd "$ROOT_DIR"
bash scripts/run_single_vs_multiprocess_fair.sh \
  --chip-configs "$CHIP_CONFIGS" \
  --sparsities "$SPARSITIES" \
  --repeats "$REPEATS" \
  --sim "$SIM" \
  --timesteps "$TIMESTEPS" \
  --interval "$INTERVAL"
EOF
chmod +x "$CMD_FILE"

nohup bash "$CMD_FILE" >"$LAUNCH_LOG" 2>&1 < /dev/null &
PID=$!
START_TIME="$(date '+%F %T')"

cat > "$LATEST_META" <<EOF
JOB_ID='$JOB_ID'
PID='$PID'
LAUNCH_LOG='$LAUNCH_LOG'
CMD_FILE='$CMD_FILE'
START_TIME='$START_TIME'
EOF

echo "Started detached job."
echo "job_id    : $JOB_ID"
echo "pid       : $PID"
echo "log       : $LAUNCH_LOG"
echo "cmd_file  : $CMD_FILE"
echo
echo "Use these commands:"
echo "  bash scripts/run_server_single_vs_multiprocess_256.sh status"
echo "  bash scripts/run_server_single_vs_multiprocess_256.sh tail"
echo "  bash scripts/run_server_single_vs_multiprocess_256.sh stop"

