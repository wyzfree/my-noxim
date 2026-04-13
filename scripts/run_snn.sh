#!/bin/bash
# Run multi-chip SNN simulation with cross-chip traffic
# Usage: ./run_snn.sh [num_chips] [dimx] [dimy] [sim_cycles]

CHIPS=${1:-4}
DIMX=${2:-8}
DIMY=${3:-8}
SIM=${4:-12000}
CONFIG="../config_examples/default_config.yaml"
TRAFFIC="../traffic_tables/cross_traffic_snn.txt"
BINARY="../bin/noxim"

echo "===== SNN simulation: chips=$CHIPS dimx=$DIMX dimy=$DIMY sim=$SIM ====="
conda run -n paper $BINARY \
    -config $CONFIG \
    -dimx $DIMX -dimy $DIMY \
    -sim $SIM \
    -chips $CHIPS \
    -cross_traffic $TRAFFIC
