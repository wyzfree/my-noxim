#!/bin/bash
# Benchmark: fixed 8x8 per chip, vary number of chips
# Usage: conda activate paper && bash run_benchmark.sh [sim_cycles]

SIM=${1:-10000}
CONFIG="../config_examples/default_config.yaml"
BINARY="../bin/noxim"
OUTFILE="../results/benchmark_$(date +%Y%m%d_%H%M%S).txt"

mkdir -p ../results

echo "===== Multi-chip benchmark (dimx=8 dimy=8 sim=$SIM) =====" | tee $OUTFILE
echo "Date: $(date)" | tee -a $OUTFILE
echo "" | tee -a $OUTFILE
echo "chips  real_time" | tee -a $OUTFILE
echo "-----  ---------" | tee -a $OUTFILE

for n in 1 2 4 8 16 32; do
    printf "%-6d " $n | tee -a $OUTFILE
    { time $BINARY -config $CONFIG -dimx 8 -dimy 8 -sim $SIM -chips $n 2>/dev/null; } 2>&1 | grep real | tee -a $OUTFILE
done

echo "" | tee -a $OUTFILE
echo "Saved to $OUTFILE"
