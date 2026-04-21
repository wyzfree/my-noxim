#!/bin/bash
# Strict-fair multi-process benchmark (FileIO mode).
# Each chip runs as an independent process.
# File topology mode:
#   - ring:  single out file per chip, next chip reads it
#   - inbox: one inbox file per chip; all sources write directly to dst inbox
# Traffic mode:
#   - ring:   direct neighbor traffic (dst=(src+1)%chips)
#   - random: random cross-chip traffic
#
# Example:
#   bash scripts/run_chip_partition_multiprocess_benchmark.sh --quick
#   bash scripts/run_chip_partition_multiprocess_benchmark.sh \
#     --chip-configs "4:16:16,16:8:8" --sparsities "0.05,0.15,0.30"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# -------------------------
# Defaults
# -------------------------
SIM=12000
REPEATS=3
TIMESTEPS=5
INTERVAL=2000
SPARSITIES="0.05,0.15,0.30"
CHIP_CONFIGS="4:16:16,16:8:8"   # chips:dimx:dimy
SEED_BASE=42

USE_CONDA=1
CONDA_ENV="paper"

CONFIG="$ROOT_DIR/config_examples/default_config.yaml"
POWER_CONFIG="$ROOT_DIR/bin/power.yaml"
BINARY="$ROOT_DIR/bin/noxim"
GENSCRIPT_RING="$ROOT_DIR/traffic_tables/gen_fair_cross_traffic_ring.py"
GENSCRIPT_RANDOM="$ROOT_DIR/traffic_tables/gen_fair_cross_traffic.py"
TRAFFIC_MODE="ring"
FILE_TOPOLOGY="ring"
RESULTS_BASE="$ROOT_DIR/results"
TRAFFIC_BASE="$ROOT_DIR/traffic_tables/generated_partition"

QUICK_MODE=0

usage() {
  cat <<'USAGE'
Usage: run_chip_partition_multiprocess_benchmark.sh [options]

Options:
  --sim N                    Simulation cycles per run
  --repeats N                Repeat count for each config/sparsity pair
  --timesteps N              Timesteps for traffic generation
  --interval N               Injection interval (cycles)
  --sparsities "a,b,c"       Comma-separated sparsity list
  --chip-configs "c:x:y,..." Comma-separated chip configs (chips:dimx:dimy)
  --seed-base N              Base seed; per-run seed = seed_base + run_id
  --config PATH              noxim config yaml path
  --power-config PATH        noxim power yaml path
  --binary PATH              noxim binary path
  --genscript-ring PATH      ring fair traffic generator path
  --genscript-random PATH    random fair traffic generator path
  --traffic-mode MODE        ring|random (default: ring)
  --file-topology MODE       ring|inbox (default: ring)
  --results-base PATH        results root directory
  --traffic-base PATH        generated traffic root directory
  --conda-env NAME           Conda env name (default: paper)
  --no-conda                 Run binary directly (without conda run)
  --quick                    Local smoke test preset
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
    --config) CONFIG="$2"; shift 2 ;;
    --power-config) POWER_CONFIG="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --genscript-ring) GENSCRIPT_RING="$2"; shift 2 ;;
    --genscript-random) GENSCRIPT_RANDOM="$2"; shift 2 ;;
    --traffic-mode) TRAFFIC_MODE="$2"; shift 2 ;;
    --file-topology) FILE_TOPOLOGY="$2"; shift 2 ;;
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
  SIM=2000
  REPEATS=1
  TIMESTEPS=3
  INTERVAL=500
  SPARSITIES="0.10"
  CHIP_CONFIGS="2:8:8,4:8:8"
fi

[[ -x "$BINARY" ]] || { echo "ERROR: binary not executable: $BINARY"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG"; exit 1; }
[[ -f "$POWER_CONFIG" ]] || { echo "ERROR: power config not found: $POWER_CONFIG"; exit 1; }
[[ -f "$GENSCRIPT_RING" ]] || { echo "ERROR: ring genscript not found: $GENSCRIPT_RING"; exit 1; }
[[ -f "$GENSCRIPT_RANDOM" ]] || { echo "ERROR: random genscript not found: $GENSCRIPT_RANDOM"; exit 1; }
[[ "$TRAFFIC_MODE" == "ring" || "$TRAFFIC_MODE" == "random" ]] || { echo "ERROR: traffic-mode must be ring or random"; exit 1; }
[[ "$FILE_TOPOLOGY" == "ring" || "$FILE_TOPOLOGY" == "inbox" ]] || { echo "ERROR: file-topology must be ring or inbox"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$RESULTS_BASE/chip_partition_multiprocess_benchmark_$TS"
TRAFFIC_DIR="$TRAFFIC_BASE/chip_partition_multiprocess_benchmark_$TS"
mkdir -p "$OUTDIR" "$TRAFFIC_DIR"

CSV="$OUTDIR/benchmark.csv"
LOG="$OUTDIR/run.log"
EMPTY_TABLE="$TRAFFIC_DIR/empty_traffic_table.txt"
cat > "$EMPTY_TABLE" <<'EOF'
% empty traffic table for strict fair multi-process benchmark
EOF

echo "timestamp,run_id,repetition,chips,dimx,dimy,total_pe,sparsity,target_entries,timesteps,interval,seed,sim,mode,traffic_file,run_dir,wall_time_sec,exit_code,valid_chip_logs" > "$CSV"

log() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG"
}

elapsed_sec() {
  local start_ns="$1"
  local end_ns="$2"
  awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1000000000.0}'
}

IFS=',' read -r -a CFG_ARR <<< "$CHIP_CONFIGS"
IFS=',' read -r -a SP_ARR <<< "$SPARSITIES"

run_id=0
log "Start multi-process benchmark."
log "OUTDIR=$OUTDIR"
log "Params: sim=$SIM repeats=$REPEATS timesteps=$TIMESTEPS interval=$INTERVAL"
log "Params: configs=$CHIP_CONFIGS sparsities=$SPARSITIES seed_base=$SEED_BASE"
log "Params: config=$CONFIG power_config=$POWER_CONFIG"
log "Params: traffic_mode=$TRAFFIC_MODE"
log "Params: file_topology=$FILE_TOPOLOGY"

for cfg in "${CFG_ARR[@]}"; do
  IFS=':' read -r chips dimx dimy <<< "$cfg"
  if [[ -z "${chips:-}" || -z "${dimx:-}" || -z "${dimy:-}" ]]; then
    log "Skip invalid config entry: $cfg"
    continue
  fi
  if [[ "$chips" -lt 1 ]]; then
    log "Skip chips<1 entry: $cfg"
    continue
  fi

  total_pe=$((chips * dimx * dimy))
  num_pe=$((dimx * dimy))

  for sparsity in "${SP_ARR[@]}"; do
    for ((rep=1; rep<=REPEATS; rep++)); do
      run_id=$((run_id + 1))
      seed=$((SEED_BASE + run_id))
      target_entries=$(awk -v pe="$total_pe" -v ts="$TIMESTEPS" -v sp="$sparsity" 'BEGIN{printf "%d", pe*ts*sp+0.5}')
      traffic_file="$TRAFFIC_DIR/${TRAFFIC_MODE}_${chips}c_${num_pe}pe_s${sparsity}_r${rep}.txt"
      run_dir="$OUTDIR/run_${run_id}_c${chips}_s${sparsity}_r${rep}"
      mkdir -p "$run_dir"

      if [[ "$TRAFFIC_MODE" == "ring" ]]; then
        python3 "$GENSCRIPT_RING" "$chips" "$num_pe" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$traffic_file" "$seed" >>"$LOG" 2>&1
      else
        python3 "$GENSCRIPT_RANDOM" "$chips" "$num_pe" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$traffic_file" "$seed" >>"$LOG" 2>&1
      fi

      if [[ "$FILE_TOPOLOGY" == "ring" ]]; then
        # one out file per chip; in file is previous chip's out file
        for ((i=0; i<chips; i++)); do
          : > "$run_dir/chip${i}_out.txt"
        done
      else
        # inbox topology: each chip owns one inbox file
        mkdir -p "$run_dir/inbox"
        for ((i=0; i<chips; i++)); do
          : > "$run_dir/inbox/chip${i}_in.txt"
        done
      fi

      log "Run #$run_id: chips=$chips dim=${dimx}x${dimy} total_pe=$total_pe sparsity=$sparsity target_entries=$target_entries rep=$rep"

      declare -a pids=()
      start_ns="$(date +%s%N)"
      for ((i=0; i<chips; i++)); do
        if [[ "$FILE_TOPOLOGY" == "ring" ]]; then
          prev=$(( (i - 1 + chips) % chips ))
          in_file="$run_dir/chip${prev}_out.txt"
          out_file="$run_dir/chip${i}_out.txt"
        else
          in_file="$run_dir/inbox/chip${i}_in.txt"
          out_file="$run_dir/inbox"
        fi
        chip_log="$run_dir/chip${i}.log"

        cmd=("$BINARY"
             -config "$CONFIG"
             -power "$POWER_CONFIG"
             -dimx "$dimx" -dimy "$dimy"
             -sim "$SIM"
             -chips "$chips"
             -chip_id "$i"
             -in_fifo "$in_file"
             -out_fifo "$out_file"
             -cross_traffic "$traffic_file"
             -traffic table "$EMPTY_TABLE")

        if [[ "$USE_CONDA" -eq 1 ]]; then
          (conda run -n "$CONDA_ENV" "${cmd[@]}") >"$chip_log" 2>&1 &
        else
          ("${cmd[@]}") >"$chip_log" 2>&1 &
        fi
        pids+=("$!")
      done

      exit_code=0
      for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
          rc=$?
          if [[ "$exit_code" -eq 0 ]]; then
            exit_code="$rc"
          fi
        fi
      done
      end_ns="$(date +%s%N)"
      wall_time="$(elapsed_sec "$start_ns" "$end_ns")"

      valid_logs=0
      for ((i=0; i<chips; i++)); do
        chip_log="$run_dir/chip${i}.log"
        if rg -q "Noxim simulation completed" "$chip_log"; then
          valid_logs=$((valid_logs + 1))
        fi
      done

      if [[ "$valid_logs" -ne "$chips" ]]; then
        # mark invalid run even if process exit status was 0
        if [[ "$exit_code" -eq 0 ]]; then
          exit_code=202
        fi
      fi

      printf "%s,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d,%s,%s,%s,%s,%s,%d\n" \
        "$(date +'%F %T')" "$run_id" "$rep" "$chips" "$dimx" "$dimy" "$total_pe" \
        "$sparsity" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$seed" "$SIM" \
        "multiprocess_${TRAFFIC_MODE}_${FILE_TOPOLOGY}_fileio" "$traffic_file" "$run_dir" "$wall_time" "$exit_code" "$valid_logs" >> "$CSV"

      if [[ "$exit_code" -ne 0 ]]; then
        log "WARNING: run #$run_id failed/invalid (exit_code=$exit_code valid_logs=$valid_logs/$chips)."
      fi
    done
  done
done

log "Done. CSV: $CSV"
log "Log : $LOG"
