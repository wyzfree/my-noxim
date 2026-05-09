#!/bin/bash
# Fair benchmark: single-process vs multi-process (FileIO inbox).
# Goal:
#   Compare end-to-end wall time under exactly the same generated cross-traffic.
#
# Key fairness rules:
#   1) same chips/dimx/dimy/sim/sparsity/target_entries/seed
#   2) same cross_traffic file for both modes
#   3) disable PE random traffic via empty table
#   4) single-process uses ChipIO, multi-process uses FileIO inbox
#
# Example:
#   conda run -n paper bash scripts/run_single_vs_multiprocess_fair.sh --quick
#   conda run -n paper bash scripts/run_single_vs_multiprocess_fair.sh \
#     --chip-configs "4:16:16,16:8:8" --sparsities "0.05,0.15,0.30" --repeats 3

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
SEED_BASE=420

USE_CONDA=1
CONDA_ENV="paper"
CONDA_PREFIX_HINT="/home/st1101/miniconda3/envs/$CONDA_ENV"

CONFIG="$ROOT_DIR/config_examples/default_config.yaml"
POWER_CONFIG="$ROOT_DIR/bin/power.yaml"
BINARY="$ROOT_DIR/bin/noxim"
FAIR_GENSCRIPT="$ROOT_DIR/traffic_tables/gen_fair_cross_traffic.py"

RESULTS_BASE="$ROOT_DIR/results"
TRAFFIC_BASE="$ROOT_DIR/traffic_tables/generated_partition"
FILE_TOPOLOGY="inbox"  # fixed for fair multi-process conflict path

QUICK_MODE=0
SKIP_MULTI_WHEN_1CHIP=0

usage() {
  cat <<'USAGE'
Usage: run_single_vs_multiprocess_fair.sh [options]

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
  --genscript PATH           fair random cross traffic generator path
  --results-base PATH        results root directory
  --traffic-base PATH        generated traffic root directory
  --conda-env NAME           Conda env name (default: paper)
  --conda-prefix PATH        Conda prefix hint for LD_LIBRARY_PATH
  --no-conda                 Run binary directly (without conda run)
  --skip-multi-when-1chip    Skip multiprocess(FileIO) run when chips=1
  --quick                    Local smoke preset
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
    --genscript) FAIR_GENSCRIPT="$2"; shift 2 ;;
    --results-base) RESULTS_BASE="$2"; shift 2 ;;
    --traffic-base) TRAFFIC_BASE="$2"; shift 2 ;;
    --conda-env) CONDA_ENV="$2"; shift 2 ;;
    --conda-prefix) CONDA_PREFIX_HINT="$2"; shift 2 ;;
    --no-conda) USE_CONDA=0; shift ;;
    --skip-multi-when-1chip) SKIP_MULTI_WHEN_1CHIP=1; shift ;;
    --quick) QUICK_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ "$QUICK_MODE" -eq 1 ]]; then
  SIM=4000
  REPEATS=1
  TIMESTEPS=3
  INTERVAL=500
  SPARSITIES="0.10"
  CHIP_CONFIGS="4:8:8"
fi

# Keep this in sync if --conda-env is overridden and --conda-prefix isn't.
if [[ "$CONDA_PREFIX_HINT" == "/home/st1101/miniconda3/envs/paper" && "$CONDA_ENV" != "paper" ]]; then
  CONDA_PREFIX_HINT="/home/st1101/miniconda3/envs/$CONDA_ENV"
fi

[[ -x "$BINARY" ]] || { echo "ERROR: binary not executable: $BINARY"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG"; exit 1; }
[[ -f "$POWER_CONFIG" ]] || { echo "ERROR: power config not found: $POWER_CONFIG"; exit 1; }
[[ -f "$FAIR_GENSCRIPT" ]] || { echo "ERROR: genscript not found: $FAIR_GENSCRIPT"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$RESULTS_BASE/single_vs_multiprocess_fair_$TS"
TRAFFIC_DIR="$TRAFFIC_BASE/single_vs_multiprocess_fair_$TS"
mkdir -p "$OUTDIR" "$TRAFFIC_DIR"

CSV="$OUTDIR/benchmark.csv"
LOG="$OUTDIR/run.log"
EMPTY_TABLE="$TRAFFIC_DIR/empty_traffic_table.txt"
cat > "$EMPTY_TABLE" <<'EOF'
% empty traffic table for fair single-vs-multiprocess benchmark
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

run_single_process() {
  local chips="$1" dimx="$2" dimy="$3" sim="$4" seed="$5" traffic_file="$6" run_dir="$7"
  local cmd=("$BINARY"
             -config "$CONFIG"
             -power "$POWER_CONFIG"
             -dimx "$dimx" -dimy "$dimy"
             -sim "$sim"
             -chips "$chips"
             -seed "$seed"
             -traffic table "$EMPTY_TABLE"
             -cross_traffic "$traffic_file")

  local start_ns end_ns wall rc=0
  start_ns="$(date +%s%N)"
  if [[ "$USE_CONDA" -eq 1 ]]; then
    if [[ "${CONDA_DEFAULT_ENV:-}" == "$CONDA_ENV" ]]; then
      if ! env LD_LIBRARY_PATH="$CONDA_PREFIX_HINT/lib:${LD_LIBRARY_PATH:-}" \
           "${cmd[@]}" >"$run_dir/single.log" 2>&1; then
        rc=$?
      fi
    else
      if ! env LD_LIBRARY_PATH="$CONDA_PREFIX_HINT/lib:${LD_LIBRARY_PATH:-}" \
           conda run -n "$CONDA_ENV" "${cmd[@]}" >"$run_dir/single.log" 2>&1; then
        rc=$?
      fi
    fi
  else
    if ! "${cmd[@]}" >"$run_dir/single.log" 2>&1; then
      rc=$?
    fi
  fi
  end_ns="$(date +%s%N)"
  wall="$(elapsed_sec "$start_ns" "$end_ns")"

  if ! rg -q "Noxim simulation completed" "$run_dir/single.log"; then
    if [[ "$rc" -eq 0 ]]; then rc=201; fi
  fi
  printf "%s|%s|1\n" "$wall" "$rc"
}

run_multi_process() {
  local chips="$1" dimx="$2" dimy="$3" sim="$4" seed="$5" traffic_file="$6" run_dir="$7"

  mkdir -p "$run_dir/inbox"
  for ((i=0; i<chips; i++)); do
    : > "$run_dir/inbox/chip${i}_in.txt"
  done

  local -a pids=()
  local start_ns end_ns wall exit_code=0 valid_logs=0
  start_ns="$(date +%s%N)"

  for ((i=0; i<chips; i++)); do
    local chip_log="$run_dir/chip${i}.log"
    local cmd=("$BINARY"
               -config "$CONFIG"
               -power "$POWER_CONFIG"
               -dimx "$dimx" -dimy "$dimy"
               -sim "$sim"
               -chips "$chips"
               -chip_id "$i"
               -seed "$seed"
               -in_fifo "$run_dir/inbox/chip${i}_in.txt"
               -out_fifo "$run_dir/inbox"
               -cross_traffic "$traffic_file"
               -traffic table "$EMPTY_TABLE")
    if [[ "$USE_CONDA" -eq 1 ]]; then
      if [[ "${CONDA_DEFAULT_ENV:-}" == "$CONDA_ENV" ]]; then
        (env LD_LIBRARY_PATH="$CONDA_PREFIX_HINT/lib:${LD_LIBRARY_PATH:-}" \
         "${cmd[@]}") >"$chip_log" 2>&1 &
      else
        (env LD_LIBRARY_PATH="$CONDA_PREFIX_HINT/lib:${LD_LIBRARY_PATH:-}" \
         conda run -n "$CONDA_ENV" "${cmd[@]}") >"$chip_log" 2>&1 &
      fi
    else
      ("${cmd[@]}") >"$chip_log" 2>&1 &
    fi
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      rc=$?
      if [[ "$exit_code" -eq 0 ]]; then
        exit_code="$rc"
      fi
    fi
  done
  end_ns="$(date +%s%N)"
  wall="$(elapsed_sec "$start_ns" "$end_ns")"

  for ((i=0; i<chips; i++)); do
    if rg -q "Noxim simulation completed" "$run_dir/chip${i}.log"; then
      valid_logs=$((valid_logs + 1))
    fi
  done
  if [[ "$valid_logs" -ne "$chips" ]]; then
    if [[ "$exit_code" -eq 0 ]]; then
      exit_code=202
    fi
  fi
  printf "%s|%s|%s\n" "$wall" "$exit_code" "$valid_logs"
}

IFS=',' read -r -a CFG_ARR <<< "$CHIP_CONFIGS"
IFS=',' read -r -a SP_ARR <<< "$SPARSITIES"

run_id=0
log "Start single-vs-multiprocess fair benchmark."
log "OUTDIR=$OUTDIR"
log "Params: sim=$SIM repeats=$REPEATS timesteps=$TIMESTEPS interval=$INTERVAL"
log "Params: configs=$CHIP_CONFIGS sparsities=$SPARSITIES seed_base=$SEED_BASE"
log "Params: file_topology=$FILE_TOPOLOGY (fixed)"
log "Params: skip_multi_when_1chip=$SKIP_MULTI_WHEN_1CHIP"
log "Params: config=$CONFIG power_config=$POWER_CONFIG"

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
      target_entries=$(awk -v pe="$total_pe" -v ts="$TIMESTEPS" -v sp="$sparsity" 'BEGIN{printf "%d", pe*ts*sp+0.5}')
      traffic_file="$TRAFFIC_DIR/random_${chips}c_${num_pe}pe_s${sparsity}_r${rep}.txt"

      python3 "$FAIR_GENSCRIPT" "$chips" "$num_pe" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$traffic_file" "$seed" >>"$LOG" 2>&1

      # 1) single-process
      run_dir_sp="$OUTDIR/run_${run_id}_single_c${chips}_s${sparsity}_r${rep}"
      mkdir -p "$run_dir_sp"
      log "Run #$run_id SINGLE: chips=$chips dim=${dimx}x${dimy} sparsity=$sparsity target_entries=$target_entries rep=$rep"
      IFS='|' read -r wall_sp exit_sp valid_sp < <(run_single_process "$chips" "$dimx" "$dimy" "$SIM" "$seed" "$traffic_file" "$run_dir_sp")
      cat "$run_dir_sp/single.log" >> "$LOG"
      printf "%s,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d,%s,%s,%s,%s,%s,%s\n" \
        "$(date +'%F %T')" "$run_id" "$rep" "$chips" "$dimx" "$dimy" "$total_pe" \
        "$sparsity" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$seed" "$SIM" \
        "singleprocess_chipio" "$traffic_file" "$run_dir_sp" "$wall_sp" "$exit_sp" "$valid_sp" >> "$CSV"

      # 2) multi-process
      if [[ "$SKIP_MULTI_WHEN_1CHIP" -eq 1 && "$chips" -eq 1 ]]; then
        log "Run #$run_id MULTI : skipped (chips=1 and --skip-multi-when-1chip enabled)"
      else
        run_dir_mp="$OUTDIR/run_${run_id}_multi_c${chips}_s${sparsity}_r${rep}"
        mkdir -p "$run_dir_mp"
        log "Run #$run_id MULTI : chips=$chips dim=${dimx}x${dimy} sparsity=$sparsity target_entries=$target_entries rep=$rep"
        IFS='|' read -r wall_mp exit_mp valid_mp < <(run_multi_process "$chips" "$dimx" "$dimy" "$SIM" "$seed" "$traffic_file" "$run_dir_mp")
        for ((i=0; i<chips; i++)); do
          cat "$run_dir_mp/chip${i}.log" >> "$LOG"
        done
        printf "%s,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d,%s,%s,%s,%s,%s,%s\n" \
          "$(date +'%F %T')" "$run_id" "$rep" "$chips" "$dimx" "$dimy" "$total_pe" \
          "$sparsity" "$target_entries" "$TIMESTEPS" "$INTERVAL" "$seed" "$SIM" \
          "multiprocess_random_inbox_fileio" "$traffic_file" "$run_dir_mp" "$wall_mp" "$exit_mp" "$valid_mp" >> "$CSV"
      fi
    done
  done
done

SUMMARY_COND="$OUTDIR/summary_by_condition.csv"
SUMMARY_OVERALL="$OUTDIR/summary_overall.csv"

python3 - "$CSV" "$SUMMARY_COND" "$SUMMARY_OVERALL" <<'PY'
import csv, math, statistics, sys
from collections import defaultdict

src, out_cond, out_overall = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
with open(src, newline='') as f:
    for r in csv.DictReader(f):
        if r["exit_code"] != "0":
            continue
        rows.append(r)

def mode_short(m):
    return "single" if m.startswith("singleprocess") else "multi"

by_key = defaultdict(lambda: {"single": [], "multi": []})
by_chip = defaultdict(lambda: {"single": [], "multi": []})
for r in rows:
    key = (int(r["chips"]), float(r["sparsity"]))
    m = mode_short(r["mode"])
    t = float(r["wall_time_sec"])
    by_key[key][m].append(t)
    by_chip[int(r["chips"])][m].append(t)

with open(out_cond, "w", newline='') as f:
    w = csv.writer(f)
    w.writerow(["chips","sparsity","n_single","avg_single_sec","std_single_sec","n_multi","avg_multi_sec","std_multi_sec","speedup_single_over_multi"])
    for (chips, sp) in sorted(by_key):
        s = by_key[(chips, sp)]["single"]
        m = by_key[(chips, sp)]["multi"]
        if not s or not m:
            continue
        avg_s = sum(s)/len(s); avg_m = sum(m)/len(m)
        std_s = statistics.pstdev(s) if len(s) > 1 else 0.0
        std_m = statistics.pstdev(m) if len(m) > 1 else 0.0
        w.writerow([chips, f"{sp:.2f}", len(s), f"{avg_s:.4f}", f"{std_s:.4f}",
                    len(m), f"{avg_m:.4f}", f"{std_m:.4f}", f"{(avg_s/avg_m):.4f}" if avg_m > 0 else "NA"])

with open(out_overall, "w", newline='') as f:
    w = csv.writer(f)
    w.writerow(["chips","n_single","avg_single_sec","n_multi","avg_multi_sec","speedup_single_over_multi"])
    for chips in sorted(by_chip):
        s = by_chip[chips]["single"]
        m = by_chip[chips]["multi"]
        if not s or not m:
            continue
        avg_s = sum(s)/len(s); avg_m = sum(m)/len(m)
        w.writerow([chips, len(s), f"{avg_s:.4f}", len(m), f"{avg_m:.4f}",
                    f"{(avg_s/avg_m):.4f}" if avg_m > 0 else "NA"])
PY

log "Done."
log "Raw CSV          : $CSV"
log "Summary condition: $SUMMARY_COND"
log "Summary overall  : $SUMMARY_OVERALL"
