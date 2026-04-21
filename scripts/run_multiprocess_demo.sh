#!/bin/bash
# Multi-process FileIO demo: 2 chips, bidirectional cross-chip traffic via files
#
# Flow:
#   chip0 crossOutThread reads cross_traffic (src=0 entries) → writes to chip0_out.txt
#   chip1 fileReaderThread reads chip0_out.txt (= chip1_in)  → injects into chip1 mesh
#
#   chip1 crossOutThread reads cross_traffic (src=1 entries) → writes to chip1_out.txt
#   chip0 fileReaderThread reads chip1_out.txt (= chip0_in)  → injects into chip0 mesh

set -e

NOXIM="$(dirname "$0")/../bin/noxim"
CONFIG="$(dirname "$0")/../config_examples/default_config.yaml"
TRAFFIC="$(dirname "$0")/../traffic_tables/cross_traffic_test.txt"
OUTDIR="$(dirname "$0")/../results/fileio_bidir_$$"
mkdir -p "$OUTDIR"

# Cross-chip traffic file (both chips read it; each filters its own src entries):
#   0 1 0 5 2000   chip0 -> chip1
#   0 1 3 10 2500  chip0 -> chip1
#   1 0 7 2 3000   chip1 -> chip0

# IPC wiring:
#   chip0_out.txt  <-- chip0 writes outgoing (src=0)  -->  chip1 reads as in_fifo
#   chip1_out.txt  <-- chip1 writes outgoing (src=1)  -->  chip0 reads as in_fifo
CHIP0_OUT="$OUTDIR/chip0_out.txt"
CHIP1_OUT="$OUTDIR/chip1_out.txt"

# Pre-create empty files so both processes can open them immediately
touch "$CHIP0_OUT" "$CHIP1_OUT"

echo "===== Multi-process Bidirectional FileIO Demo ====="
echo "Results in: $OUTDIR"
echo "Cross-traffic: $TRAFFIC"
echo ""
echo "Launching Chip 0 and Chip 1 in parallel..."

# Launch chip 0:  sends  0->1 traffic via crossOutThread
#                 receives  1->0 traffic from chip1_out (=chip0_in)
CONDA_PREFIX=/home/st1101/miniconda3/envs/paper \
  LD_LIBRARY_PATH=/home/st1101/miniconda3/envs/paper/lib:$LD_LIBRARY_PATH \
  "$NOXIM" -config "$CONFIG" \
    -chip_id 0 \
    -in_fifo  "$CHIP1_OUT" \
    -out_fifo "$CHIP0_OUT" \
    -cross_traffic "$TRAFFIC" \
    -sim 5000 \
    > "$OUTDIR/chip0.log" 2>&1 &
PID0=$!

# Launch chip 1:  sends  1->0 traffic via crossOutThread
#                 receives  0->1 traffic from chip0_out (=chip1_in)
CONDA_PREFIX=/home/st1101/miniconda3/envs/paper \
  LD_LIBRARY_PATH=/home/st1101/miniconda3/envs/paper/lib:$LD_LIBRARY_PATH \
  "$NOXIM" -config "$CONFIG" \
    -chip_id 1 \
    -in_fifo  "$CHIP0_OUT" \
    -out_fifo "$CHIP1_OUT" \
    -cross_traffic "$TRAFFIC" \
    -sim 5000 \
    > "$OUTDIR/chip1.log" 2>&1 &
PID1=$!

echo "  Chip 0 PID: $PID0  (in=$CHIP1_OUT, out=$CHIP0_OUT)"
echo "  Chip 1 PID: $PID1  (in=$CHIP0_OUT, out=$CHIP1_OUT)"
echo ""

wait $PID0; RC0=$?
wait $PID1; RC1=$?

echo "===== Chip 0 Output ====="
cat "$OUTDIR/chip0.log"

echo ""
echo "===== Chip 1 Output ====="
cat "$OUTDIR/chip1.log"

echo ""
echo "===== chip0_out.txt (chip0->chip1 packets, read by chip1) ====="
cat "$CHIP0_OUT"

echo ""
echo "===== chip1_out.txt (chip1->chip0 packets, read by chip0) ====="
cat "$CHIP1_OUT"

[ $RC0 -ne 0 ] || [ $RC1 -ne 0 ] && echo "" && echo "WARNING: exit codes: chip0=$RC0 chip1=$RC1"
echo ""
echo "Demo complete. Logs in $OUTDIR/"
