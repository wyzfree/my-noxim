#!/bin/bash
# Run MNIST-driven SNN simulation (3 chips) with traffic regenerated each run.
#
# This keeps the proven FileIO multi-process path, but avoids using a fixed
# pre-baked traffic file. Instead, it regenerates cross-chip spike traffic
# from real MNIST samples and trained weights before every simulation.
#
# Usage:
#   bash scripts/run_snn_mnist_real.sh [num_images] [timesteps] [interval] [dim] [sim_margin] [start_idx]
#
# Defaults:
#   num_images = 10
#   timesteps  = 8
#   interval   = 500
#   dim        = 4
#   sim_margin = 2000
#   start_idx  = 0

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
NOXIM="$BIN_DIR/noxim"
CONFIG="$ROOT_DIR/config_examples/default_config.yaml"
GEN_SCRIPT="$ROOT_DIR/snn/gen_mnist_traffic.py"
EVAL_SCRIPT="$ROOT_DIR/snn/eval_mnist_chip_pred.py"

NUM_IMAGES=${1:-10}
TIMESTEPS=${2:-8}
INTERVAL=${3:-500}
DIM=${4:-4}
SIM_MARGIN=${5:-2000}
START_IDX=${6:-0}

OUTDIR="$ROOT_DIR/results/snn_mnist_real_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
TRAFFIC="$OUTDIR/mnist_snn_traffic_runtime.txt"

export CONDA_PREFIX=/home/st1101/miniconda3/envs/paper
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
PYTHON_BIN="$CONDA_PREFIX/bin/python"

run_chip() { cd "$BIN_DIR" && exec "$@"; }

echo "======================================================="
echo "  SNN MNIST Real Task (runtime traffic generation)"
echo "======================================================="
echo "Output dir : $OUTDIR"
echo "Params     : images=$NUM_IMAGES timesteps=$TIMESTEPS interval=$INTERVAL dim=$DIM start_idx=$START_IDX"
echo ""

echo "[1/3] Generating traffic from MNIST + trained weights..."
"$PYTHON_BIN" "$GEN_SCRIPT" "$NUM_IMAGES" "$TIMESTEPS" "$INTERVAL" "$DIM" "$TRAFFIC" "$START_IDX" \
  > "$OUTDIR/traffic_gen.log" 2>&1

if [ ! -s "$TRAFFIC" ]; then
    echo "ERROR: generated traffic file is empty: $TRAFFIC"
    exit 1
fi

EXPECTED_01=$(awk '($1 !~ /^#/ && $1==0 && $2==1){c++} END{print c+0}' "$TRAFFIC")
EXPECTED_12=$(awk '($1 !~ /^#/ && $1==1 && $2==2){c++} END{print c+0}' "$TRAFFIC")
MAX_CYCLE=$(awk '($1 !~ /^#/ && NF>=5){if($5>m)m=$5} END{print m+0}' "$TRAFFIC")
SIM_CYCLES=$((MAX_CYCLE + SIM_MARGIN))
WARMUP=1000

echo "[2/3] Launching multi-process simulation..."
echo "Traffic    : $TRAFFIC"
echo "Expected   : chip0->1=$EXPECTED_01 packets, chip1->2=$EXPECTED_12 packets"
echo "Sim cycles : $SIM_CYCLES (+1000 reset)"
echo ""

CHIP0_OUT="$OUTDIR/chip0_out.txt"
CHIP1_OUT="$OUTDIR/chip1_out.txt"
CHIP2_OUT="$OUTDIR/chip2_out.txt"
touch "$CHIP0_OUT" "$CHIP1_OUT" "$CHIP2_OUT"

WALL_START=$(date +%s%N)

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 0 \
    -in_fifo "$CHIP2_OUT" \
    -out_fifo "$CHIP0_OUT" \
    -cross_traffic "$TRAFFIC" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" ) > "$OUTDIR/chip0.log" 2>&1 &
PID0=$!

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 1 \
    -in_fifo "$CHIP0_OUT" \
    -out_fifo "$CHIP1_OUT" \
    -cross_traffic "$TRAFFIC" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" ) > "$OUTDIR/chip1.log" 2>&1 &
PID1=$!

( run_chip "$NOXIM" -config "$CONFIG" \
    -chip_id 2 \
    -in_fifo "$CHIP1_OUT" \
    -out_fifo "$CHIP2_OUT" \
    -cross_traffic "$TRAFFIC" \
    -sim "$SIM_CYCLES" -warmup "$WARMUP" ) > "$OUTDIR/chip2.log" 2>&1 &
PID2=$!

wait $PID0; RC0=$?
wait $PID1; RC1=$?
wait $PID2; RC2=$?

WALL_END=$(date +%s%N)
WALL_MS=$(( (WALL_END - WALL_START) / 1000000 ))

echo "[3/4] Collecting communication results..."

extract_stat() {
    local log=$1 key=$2
    grep "$key" "$log" | grep -oP '\d+' | head -1
}

TX0=$(extract_stat "$OUTDIR/chip0.log" "Packets written to out_fifo")
TX1=$(extract_stat "$OUTDIR/chip1.log" "Packets written to out_fifo")
RX1=$(extract_stat "$OUTDIR/chip1.log" "Flits read from in_fifo")
RX2=$(extract_stat "$OUTDIR/chip2.log" "Flits read from in_fifo")

echo "Wall-clock : ${WALL_MS} ms"
echo "Summary    :"
echo "  chip0 TX packets : ${TX0:-?}"
echo "  chip1 TX packets : ${TX1:-?}"
echo "  chip1 RX flits   : ${RX1:-?}"
echo "  chip2 RX flits   : ${RX2:-?}"
echo ""

OK=1
check() {
    local label=$1 got=$2 expected=$3
    if [ "${got:-0}" -eq "$expected" ] 2>/dev/null; then
        echo "  [PASS] $label: $got == $expected"
    else
        echo "  [FAIL] $label: got=${got:-?} expected=$expected"
        OK=0
    fi
}

check "chip0 TX (->chip1 packets)" "$TX0" "$EXPECTED_01"
check "chip1 TX (->chip2 packets)" "$TX1" "$EXPECTED_12"
check "chip1 RX flits (from chip0)" "$RX1" $(( EXPECTED_01 * 2 ))
check "chip2 RX flits (from chip1)" "$RX2" $(( EXPECTED_12 * 2 ))
echo ""

if [ $RC0 -ne 0 ] || [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ]; then
    echo "WARNING: exit codes chip0=$RC0 chip1=$RC1 chip2=$RC2"
    exit 1
fi

if [ "$OK" -eq 1 ]; then
    echo "All checks PASSED."
else
    echo "Some checks FAILED."
    exit 1
fi

echo ""
echo "[4/4] Evaluating chip-side predictions..."
"$PYTHON_BIN" "$EVAL_SCRIPT" "$CHIP1_OUT" "$NUM_IMAGES" "$TIMESTEPS" "$INTERVAL" "$START_IDX" \
  > "$OUTDIR/chip_eval.log" 2>&1
cat "$OUTDIR/chip_eval.log"

echo "Logs and generated traffic: $OUTDIR/"
