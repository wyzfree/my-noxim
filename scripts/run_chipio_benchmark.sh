#!/bin/bash
# ChipIO benchmark: fixed total 256 PEs, vary chip count and size
# Each config generates its own cross-chip traffic file before simulating.
# Usage: conda activate paper && bash run_chipio_benchmark.sh [sim_cycles]

SIM=${1:-10000}
CONFIG="../config_examples/default_config.yaml"
BINARY="../bin/noxim"
GENSCRIPT="../traffic_tables/gen_cross_traffic.py"
OUTFILE="../results/chipio_benchmark_$(date +%Y%m%d_%H%M%S).txt"

mkdir -p ../results ../traffic_tables

echo "===== ChipIO benchmark (total 256 PEs, sim=$SIM) =====" | tee $OUTFILE
echo "Date: $(date)" | tee -a $OUTFILE
echo "" | tee -a $OUTFILE
echo "chips  dimx  dimy  total_PE  real_time" | tee -a $OUTFILE
echo "-----  ----  ----  --------  ---------" | tee -a $OUTFILE

# chips / dimx / dimy
configs=(
    "1  16  16"
    "4   8   8"
    "16  4   4"
    "64  2   2"
)

for cfg in "${configs[@]}"; do
    read chips dimx dimy <<< $cfg
    total=$((chips * dimx * dimy))
    num_pe=$((dimx * dimy))

    # Generate cross-chip traffic for this config
    traffic_file="../traffic_tables/cross_traffic_${chips}chips_${num_pe}pe.txt"
    python3 $GENSCRIPT $chips $num_pe 5 2000 0.15 $traffic_file > /dev/null

    printf "%-6d %-5d %-5d %-9d " $chips $dimx $dimy $total | tee -a $OUTFILE

    if [ $chips -eq 1 ]; then
        # Single chip: no cross-chip traffic
        { time $BINARY -config $CONFIG -dimx $dimx -dimy $dimy -sim $SIM -chips $chips 2>/dev/null; } 2>&1 | grep real | tee -a $OUTFILE
    else
        { time $BINARY -config $CONFIG -dimx $dimx -dimy $dimy -sim $SIM -chips $chips -cross_traffic $traffic_file 2>/dev/null; } 2>&1 | grep real | tee -a $OUTFILE
    fi
done

echo "" | tee -a $OUTFILE
echo "Saved to $OUTFILE"
