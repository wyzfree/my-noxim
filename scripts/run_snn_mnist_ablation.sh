#!/bin/bash
# Experiment 3 ablation: compare SNN accuracy at T=8 vs T=16 on N MNIST images.
# ANN baseline accuracy is printed by gen_mnist_traffic.py as part of each run.
#
# Usage: bash scripts/run_snn_mnist_ablation.sh [num_images] [start_idx]
# Defaults: num_images=100, start_idx=0

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
RUN_SCRIPT="$SCRIPT_DIR/run_snn_mnist_real.sh"

NUM_IMAGES=${1:-100}
START_IDX=${2:-0}

OUTDIR="$ROOT_DIR/results/snn_mnist_ablation_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

echo "SNN MNIST Ablation: num_images=$NUM_IMAGES start_idx=$START_IDX" | tee "$SUMMARY"
echo "Date: $(date)" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"
printf "%-12s %-18s %-18s %-10s\n" "T" "ANN_accuracy" "SNN_accuracy" "wall_s" | tee -a "$SUMMARY"
echo "------------------------------------------------------------" | tee -a "$SUMMARY"

run_condition() {
    local T=$1
    local logdir="$OUTDIR/T${T}"
    mkdir -p "$logdir"

    local t0
    t0=$(date +%s)

    bash "$RUN_SCRIPT" "$NUM_IMAGES" "$T" 500 4 2000 "$START_IDX" \
        > "$logdir/run.log" 2>&1

    local t1
    t1=$(date +%s)
    local wall=$(( t1 - t0 ))

    # Most-recent snn_mnist_real result dir contains traffic_gen.log and chip_eval.log
    local rdir
    rdir=$(ls -dt "$ROOT_DIR/results/snn_mnist_real_"* 2>/dev/null | head -1)
    cp "$rdir/traffic_gen.log" "$logdir/" 2>/dev/null || true
    cp "$rdir/chip_eval.log"   "$logdir/" 2>/dev/null || true

    local ann_acc snn_acc
    ann_acc=$(grep "^Accuracy:" "$logdir/traffic_gen.log" 2>/dev/null | grep -oP '\d+/\d+' || echo "?/?")
    snn_acc=$(grep "^Accuracy:" "$logdir/chip_eval.log"   2>/dev/null | grep -oP '\d+/\d+' || echo "?/?")

    printf "%-12s %-18s %-18s %-10s\n" "$T" "$ann_acc" "$snn_acc" "${wall}s" | tee -a "$SUMMARY"
}

run_condition 8
run_condition 16

echo "" | tee -a "$SUMMARY"
echo "Full logs: $OUTDIR/" | tee -a "$SUMMARY"
