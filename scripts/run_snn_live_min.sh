#!/bin/bash
# Minimal live-SNN loop (no precomputed cross_traffic table):
#   chip0 computes spikes locally and forwards to chip1
#   chip1 integrates incoming spikes and forwards to chip2
#   chip2 only receives (fanout=0)
#
# This script is intentionally separate from run_snn_v1.sh so legacy
# traffic-table replay flow remains unchanged.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
NOXIM="$BIN_DIR/noxim"
CONFIG="$SCRIPT_DIR/../config_examples/default_config.yaml"
OUTDIR="$SCRIPT_DIR/../results/snn_live_min_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

export CONDA_PREFIX=/home/st1101/miniconda3/envs/paper
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"

run_chip() { cd "$BIN_DIR" && exec "$@"; }

CHIP0_OUT="$OUTDIR/chip0_out.txt"
CHIP1_OUT="$OUTDIR/chip1_out.txt"
CHIP2_OUT="$OUTDIR/chip2_out.txt"
touch "$CHIP0_OUT" "$CHIP1_OUT" "$CHIP2_OUT"

SIM_CYCLES=${1:-12000}
WARMUP=1000
SNN_TS=500
SNN_TH=1.0
SNN_LEAK=0.9

echo "======================================================="
echo "  SNN Live Minimal Loop (computed spikes, 3 chips)"
echo "======================================================="
echo "Results dir : $OUTDIR"
echo "Sim cycles  : $SIM_CYCLES (+1000 reset)"
echo ""

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 0 \
    -in_fifo "$CHIP2_OUT" \
    -out_fifo "$CHIP0_OUT" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" \
    -snn_mode \
    -snn_ts_cycles "$SNN_TS" \
    -snn_threshold "$SNN_TH" \
    -snn_leak "$SNN_LEAK" \
    -snn_weight 0.30 \
    -snn_bias 0.20 \
    -snn_fanout 4 \
    -snn_target_chip 1 ) > "$OUTDIR/chip0.log" 2>&1 &
PID0=$!

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 1 \
    -in_fifo "$CHIP0_OUT" \
    -out_fifo "$CHIP1_OUT" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" \
    -snn_mode \
    -snn_ts_cycles "$SNN_TS" \
    -snn_threshold "$SNN_TH" \
    -snn_leak "$SNN_LEAK" \
    -snn_weight 0.30 \
    -snn_bias 0.00 \
    -snn_fanout 4 \
    -snn_target_chip 2 ) > "$OUTDIR/chip1.log" 2>&1 &
PID1=$!

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 2 \
    -in_fifo "$CHIP1_OUT" \
    -out_fifo "$CHIP2_OUT" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" \
    -snn_mode \
    -snn_ts_cycles "$SNN_TS" \
    -snn_threshold "$SNN_TH" \
    -snn_leak "$SNN_LEAK" \
    -snn_weight 0.30 \
    -snn_bias 0.00 \
    -snn_fanout 0 \
    -snn_target_chip -1 ) > "$OUTDIR/chip2.log" 2>&1 &
PID2=$!

echo "Launched: chip0=$PID0 chip1=$PID1 chip2=$PID2"

wait $PID0; RC0=$?
wait $PID1; RC1=$?
wait $PID2; RC2=$?

echo ""
echo "------- FileIO Summary -------"
for chip in 0 1 2; do
    log="$OUTDIR/chip${chip}.log"
    tx=$(grep "Packets written to out_fifo" "$log" | grep -oP '\d+' | head -1)
    parsed=$(grep "Packet records parsed from in_fifo" "$log" | grep -oP '\d+' | head -1)
    rx=$(grep "Flits read from in_fifo and injected" "$log" | grep -oP '\d+' | head -1)
    echo "chip${chip}: tx_records=${tx:-?} parsed_in_records=${parsed:-?} rx_flits=${rx:-?}"
done

echo ""
echo "Logs: $OUTDIR/"
if [ $RC0 -ne 0 ] || [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ]; then
    echo "WARNING exit codes: $RC0 $RC1 $RC2"
    exit 1
fi
