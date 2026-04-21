#!/bin/bash
# Fixed-total-PE benchmark for chip partitioning.
# Goal: compare 1x32x32 vs 4x16x16 vs 16x8x8 under strict-fair traffic input.
#
# Examples:
#   bash scripts/run_chip_partition_benchmark.sh --quick
#   bash scripts/run_chip_partition_benchmark.sh --sim 12000 --repeats 3
#   bash scripts/run_chip_partition_benchmark.sh \
#     --chip-configs "1:32:32,4:16:16,16:8:8" \
#     --sparsities "0.05,0.15,0.30" --timesteps 8 --interval 1500

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# -------------------------
# Default parameters (edit here for local/server)
# -------------------------
SIM=12000
REPEATS=3
TIMESTEPS=5
INTERVAL=2000
SPARSITIES="0.05,0.15,0.30"
CHIP_CONFIGS="1:32:32,4:16:16,16:8:8"  # chips:dimx:dimy
SEED_BASE=42
STRICT_FAIR=1

USE_CONDA=1
CONDA_ENV="paper"

CONFIG="$ROOT_DIR/config_examples/default_config.yaml"
POWER_CONFIG="$ROOT_DIR/bin/power.yaml"
BINARY="$ROOT_DIR/bin/noxim"
GENSCRIPT="$ROOT_DIR/traffic_tables/gen_cross_traffic.py"
FAIR_GENSCRIPT="$ROOT_DIR/traffic_tables/gen_fair_cross_traffic.py"
RESULTS_BASE="$ROOT_DIR/results"
TRAFFIC_BASE="$ROOT_DIR/traffic_tables/generated_partition"

QUICK_MODE=0

usage() {
  cat <<'USAGE'
Usage: run_chip_partition_benchmark.sh [options]

Options:
  --sim N                    Simulation cycles per run
  --repeats N                Repeat count for each config/sparsity pair
  --timesteps N              Timesteps for traffic generation
  --interval N               Injection interval (cycles)
  --sparsities "a,b,c"       Comma-separated sparsity list
  --chip-configs "c:x:y,..." Comma-separated chip configs (chips:dimx:dimy)
  --seed-base N              Base seed; per-run seed = seed_base + run_id
  --strict-fair 0|1          1: strict fair mode (default), 0: legacy mode
  --config PATH              noxim config yaml path
  --power-config PATH        noxim power yaml path
  --binary PATH              noxim binary path
  --genscript PATH           traffic generator path
  --results-base PATH        results root directory
  --traffic-base PATH        generated traffic root directory
  --conda-env NAME           Conda env name (default: paper)
  --no-conda                 Run binary directly (without conda run)
  --quick                    Local smoke test preset (small/faster)
  -h, --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) SIM="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --timesteps) TIMESTEPS="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --sparsities) SPARSITIES="$2"; shift 2 ;;
    --chip-configs) CHIP_CONFIGS="$2"; shift 2 ;;
    --seed-base) SEED_BASE="$2"; shift 2 ;;
    --strict-fair) STRICT_FAIR="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --power-config) POWER_CONFIG="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --genscript) GENSCRIPT="$2"; shift 2 ;;
    --results-base) RESULTS_BASE="$2"; shift 2 ;;
    --traffic-base) TRAFFIC_BASE="$2"; shift 2 ;;
    --conda-env) CONDA_ENV="$2"; shift 2 ;;
    --no-conda) USE_CONDA=0; shift ;;
    --quick) QUICK_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ "$QUICK_MODE" -eq 1 ]]; then
  # Quick local smoke test (you can still override manually via flags).
  SIM=2000
  REPEATS=1
  TIMESTEPS=3
  INTERVAL=500
  SPARSITIES="0.10"
fi

[[ -x "$BINARY" ]] || { echo "ERROR: binary not executable: $BINARY"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG"; exit 1; }
[[ -f "$POWER_CONFIG" ]] || { echo "ERROR: power config not found: $POWER_CONFIG"; exit 1; }
[[ -f "$GENSCRIPT" ]] || { echo "ERROR: genscript not found: $GENSCRIPT"; exit 1; }
[[ -f "$FAIR_GENSCRIPT" ]] || { echo "ERROR: fair genscript not found: $FAIR_GENSCRIPT"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$RESULTS_BASE/chip_partition_benchmark_$TS"
TRAFFIC_DIR="$TRAFFIC_BASE/chip_partition_benchmark_$TS"
mkdir -p "$OUTDIR" "$TRAFFIC_DIR"

CSV="$OUTDIR/benchmark.csv"
LOG="$OUTDIR/run.log"
EMPTY_TABLE="$TRAFFIC_DIR/empty_traffic_table.txt"

cat > "$EMPTY_TABLE" <<'EOF'
% empty traffic table for strict fair benchmark
EOF

echo "timestamp,run_id,repetition,chips,dimx,dimy,total_pe,sparsity,target_entries,timesteps,interval,seed,sim,strict_fair,traffic_file,wall_time_sec,exit_code" > "$CSV"

log() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG"
}

run_cmd_with_time() {
  # Args are the command to run.
  local tmp_time
  local tmp_out
  tmp_time="$(mktemp)"
  tmp_out="$(mktemp)"

  local rc=0
  if ! /usr/bin/time -q -f "%e" -o "$tmp_time" "$@" >"$tmp_out" 2>&1; then
    rc=$?
  fi

  # Persist full command output into run.log
  cat "$tmp_out" >>"$LOG"

  # Detect silent-invalid runs (e.g., missing power yaml exits with code 0).
  if grep -q "No YAML power configurations file found!" "$tmp_out"; then
    rc=200
  fi
  if ! grep -q "Noxim simulation completed" "$tmp_out"; then
    # Keep explicit failure even if command returned 0.
    if [[ "$rc" -eq 0 ]]; then
      rc=201
    fi
  fi

  local t
  t="$(cat "$tmp_time" 2>/dev/null || echo "NA")"
  rm -f "$tmp_time" "$tmp_out"
  printf "%s|%s\n" "$t" "$rc"
}

IFS=',' read -r -a CFG_ARR <<< "$CHIP_CONFIGS"
IFS=',' read -r -a SP_ARR <<< "$SPARSITIES"

run_id=0
log "Start benchmark."
log "OUTDIR=$OUTDIR"
log "Params: sim=$SIM repeats=$REPEATS timesteps=$TIMESTEPS interval=$INTERVAL"
log "Params: configs=$CHIP_CONFIGS sparsities=$SPARSITIES seed_base=$SEED_BASE"
log "Params: config=$CONFIG power_config=$POWER_CONFIG"
log "Params: strict_fair=$STRICT_FAIR"

for cfg in "${CFG_ARR[@]}"; do
  IFS=':' read -r chips dimx dimy <<< "$cfg"
  if [[ -z "${chips:-}" || -z "${dimx:-}" || -z "${dimy:-}" ]]; then
    log "Skip invalid config entry: $cfg"
    continue
  fi

  total_pe=$((chips * dimx * dimy))
  num_pe=$((dimx * dimy))

  for sparsity in "${SP_ARR[@]}"; do
    for ((rep=1; rep<=REPEATS; rep++)); do
      run_id=$((run_id + 1))
      seed=$((SEED_BASE + run_id))
      traffic_file="$TRAFFIC_DIR/cross_${chips}c_${num_pe}pe_s${sparsity}_r${rep}.txt"
      target_entries=$(awk -v pe="$total_pe" -v ts="$TIMESTEPS" -v sp="$sparsity" 'BEGIN{printf "%d", pe*ts*sp+0.5}')

      if [[ "$STRICT_FAIR" -eq 1 ]]; then
        # Strict fairness:
        # 1) equal target entries for same sparsity across chip partitions
        # 2) all configs (including chips=1) use explicit cross_traffic
        # 3) random PE traffic disabled via "-traffic table <empty>"
        python3 "$FAIR_GENSCRIPT" "$chips" "$num_pe" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$traffic_file" "$seed" >>"$LOG" 2>&1
      else
        if [[ "$chips" -gt 1 ]]; then
          python3 "$GENSCRIPT" "$chips" "$num_pe" "$TIMESTEPS" "$INTERVAL" "$sparsity" "$traffic_file" "$seed" >>"$LOG" 2>&1
        else
          traffic_file="NA"
        fi
      fi

      log "Run #$run_id: chips=$chips dim=${dimx}x${dimy} total_pe=$total_pe sparsity=$sparsity target_entries=$target_entries rep=$rep"

      cmd=("$BINARY" -config "$CONFIG" -power "$POWER_CONFIG" -dimx "$dimx" -dimy "$dimy" -sim "$SIM" -chips "$chips")
      if [[ "$STRICT_FAIR" -eq 1 ]]; then
        cmd+=(-traffic table "$EMPTY_TABLE")
        cmd+=(-cross_traffic "$traffic_file")
      elif [[ "$chips" -gt 1 ]]; then
        cmd+=(-cross_traffic "$traffic_file")
      fi

      if [[ "$USE_CONDA" -eq 1 ]]; then
        full_cmd=(conda run -n "$CONDA_ENV" "${cmd[@]}")
      else
        full_cmd=("${cmd[@]}")
      fi

      IFS='|' read -r wall_time exit_code < <(run_cmd_with_time "${full_cmd[@]}")

      printf "%s,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d,%d,%s,%s,%s\n" \
        "$(date +'%F %T')" "$run_id" "$rep" "$chips" "$dimx" "$dimy" "$total_pe" \
        "$sparsity" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$seed" "$SIM" "$STRICT_FAIR" "${traffic_file:-NA}" \
        "$wall_time" "$exit_code" >> "$CSV"

      if [[ "$exit_code" != "0" ]]; then
        log "WARNING: run #$run_id failed (exit_code=$exit_code)."
      fi
    done
  done
done

log "Done. CSV: $CSV"
log "Log : $LOG"
