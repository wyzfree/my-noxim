#!/bin/bash
# Smoke test: online cross-chip SNN spike generation via FileIO
# 2 chips, each 4x4, snn_cross_chip_fanout=1, 10 timesteps

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/bin/noxim"
CONFIG="$ROOT/config_examples/default_config.yaml"
POWER="$ROOT/bin/power.yaml"
OUTDIR="$ROOT/results/snn_cross_chip_smoke_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR/inbox"

CHIPS=2; DIMX=4; DIMY=4; SIM=2000; SEED=42
SNN_OPTS="-snn_mode -snn_ts_cycles 100 -snn_bias 0.2 -snn_leak 0.9 \
          -snn_threshold 1.0 -snn_weight 0.3 -snn_fanout 2 \
          -snn_cross_chip_fanout 1"

# Create empty inboxes
for ((i=0; i<CHIPS; i++)); do : > "$OUTDIR/inbox/chip${i}_in.txt"; done

echo "=== SNN cross-chip smoke test ===" | tee "$OUTDIR/run.log"
echo "chips=$CHIPS dim=${DIMX}x${DIMY} sim=$SIM" | tee -a "$OUTDIR/run.log"

PIDS=()
for ((i=0; i<CHIPS; i++)); do
    CMD=("$BINARY"
         -config "$CONFIG" -power "$POWER"
         -dimx "$DIMX" -dimy "$DIMY"
         -sim "$SIM" -chips "$CHIPS" -chip_id "$i" -seed "$SEED"
         -in_fifo  "$OUTDIR/inbox/chip${i}_in.txt"
         -out_fifo "$OUTDIR/inbox"
         $SNN_OPTS)
    env LD_LIBRARY_PATH="/home/st1101/miniconda3/envs/paper/lib:${LD_LIBRARY_PATH:-}" \
        "${CMD[@]}" > "$OUTDIR/chip${i}.log" 2>&1 &
    PIDS+=($!)
done

for pid in "${PIDS[@]}"; do wait "$pid"; done

echo "" | tee -a "$OUTDIR/run.log"
echo "--- inbox record counts ---" | tee -a "$OUTDIR/run.log"
for ((i=0; i<CHIPS; i++)); do
    n=$(grep -c "^[0-9]" "$OUTDIR/inbox/chip${i}_in.txt" 2>/dev/null || echo 0)
    echo "  chip${i}_in.txt: $n records" | tee -a "$OUTDIR/run.log"
done

echo "" | tee -a "$OUTDIR/run.log"
echo "--- FileIO stats ---" | tee -a "$OUTDIR/run.log"
for ((i=0; i<CHIPS; i++)); do
    echo "  [chip $i]" | tee -a "$OUTDIR/run.log"
    grep -E "written|parsed|injected|Noxim simulation" "$OUTDIR/chip${i}.log" \
        | tee -a "$OUTDIR/run.log"
done

echo "" | tee -a "$OUTDIR/run.log"
echo "--- sample records in chip0_in.txt ---" | tee -a "$OUTDIR/run.log"
head -5 "$OUTDIR/inbox/chip0_in.txt" | tee -a "$OUTDIR/run.log"
echo "--- sample records in chip1_in.txt ---" | tee -a "$OUTDIR/run.log"
head -5 "$OUTDIR/inbox/chip1_in.txt" | tee -a "$OUTDIR/run.log"

echo "" | tee -a "$OUTDIR/run.log"
echo "Done. Results in $OUTDIR"
