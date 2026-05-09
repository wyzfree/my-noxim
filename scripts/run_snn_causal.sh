#!/bin/bash
# Experiment 2: Cross-chip SNN causal propagation validation
# chip0: bias=0.3 (self-fires), chip1: bias=0.0 (only fires if driven by chip0)
# Two runs: connected (cross_chip_fanout=2) vs control (cross_chip_fanout=0)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/bin/noxim"
CONFIG="$ROOT/config_examples/default_config.yaml"
POWER="$ROOT/bin/power.yaml"
OUTDIR="$ROOT/results/snn_causal_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

CHIPS=2; DIMX=4; DIMY=4; SIM=4000; SEED=42
# bias=0.3,0.0 -> chip0 self-fires, chip1 passive
# weight=0.5, cross_chip_fanout=2 -> chip0 fires: 2 spikes to chip1, input_acc=1.0 >= threshold
COMMON_OPTS="-snn_mode -snn_ts_cycles 100 -snn_threshold 1.0 -snn_leak 0.9 \
             -snn_weight 0.5 -snn_fanout 0 -snn_bias 0.3,0.0"

run_chips() {
    local fanout=$1 rundir=$2
    mkdir -p "$rundir/inbox"
    for ((i=0; i<CHIPS; i++)); do : > "$rundir/inbox/chip${i}_in.txt"; done
    local pids=()
    for ((i=0; i<CHIPS; i++)); do
        env LD_LIBRARY_PATH="/home/st1101/miniconda3/envs/paper/lib:${LD_LIBRARY_PATH:-}" \
            "$BINARY" \
            -config "$CONFIG" -power "$POWER" \
            -dimx "$DIMX" -dimy "$DIMY" \
            -sim "$SIM" -chips "$CHIPS" -chip_id "$i" -seed "$SEED" \
            -in_fifo  "$rundir/inbox/chip${i}_in.txt" \
            -out_fifo "$rundir/inbox" \
            $COMMON_OPTS -snn_cross_chip_fanout "$fanout" \
            > "$rundir/chip${i}.log" 2>&1 &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
}

echo "=== SNN Causal Propagation Experiment ===" | tee "$OUTDIR/run.log"
echo "chip0 bias=0.3 (self-fires)  chip1 bias=0.0 (passive)" | tee -a "$OUTDIR/run.log"
echo "" | tee -a "$OUTDIR/run.log"

# --- Run A: connected (cross_chip_fanout=2) ---
echo "[A] Connected: cross_chip_fanout=2" | tee -a "$OUTDIR/run.log"
run_chips 2 "$OUTDIR/connected"
for i in 0 1; do
    n=$(grep -c "^[0-9]" "$OUTDIR/connected/inbox/chip${i}_in.txt" 2>/dev/null || echo 0)
    echo "  chip${i}_in.txt records: $n" | tee -a "$OUTDIR/run.log"
done
grep -E "written|parsed|injected|Pending" "$OUTDIR/connected/chip0.log" | tail -5 | tee -a "$OUTDIR/run.log"
grep -E "written|parsed|injected|Pending" "$OUTDIR/connected/chip1.log" | tail -5 | tee -a "$OUTDIR/run.log"

echo "" | tee -a "$OUTDIR/run.log"

# --- Run B: control (cross_chip_fanout=0, no cross-chip spikes) ---
echo "[B] Control:   cross_chip_fanout=0" | tee -a "$OUTDIR/run.log"
run_chips 0 "$OUTDIR/control"
for i in 0 1; do
    n=$(grep -c "^[0-9]" "$OUTDIR/control/inbox/chip${i}_in.txt" 2>/dev/null || echo 0)
    echo "  chip${i}_in.txt records: $n" | tee -a "$OUTDIR/run.log"
done

echo "" | tee -a "$OUTDIR/run.log"
echo "--- Expected result ---" | tee -a "$OUTDIR/run.log"
echo "  [A] chip1_in.txt > 0  (chip1 receives spikes from chip0)" | tee -a "$OUTDIR/run.log"
echo "  [B] chip1_in.txt = 0  (no cross-chip connection, chip1 silent)" | tee -a "$OUTDIR/run.log"
echo "" | tee -a "$OUTDIR/run.log"
echo "Done. Results in $OUTDIR"
