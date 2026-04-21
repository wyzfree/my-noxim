#!/bin/bash
# Strong-interaction live SNN demo (multi-process + FileIO inbox mode).
# No precomputed cross_traffic table is used.
#
# Interaction graph (default):
#   chip0 (bias>0) ----\
#                        > chip2 (bias=0) ----> chip3 (bias=0, sink)
#   chip1 (bias>0) ----/
#
# This demonstrates runtime-generated spikes:
# packets written by source chips are read by another chip, integrated by PE,
# and can trigger new spikes forwarded to the next chip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
NOXIM="$BIN_DIR/noxim"
CONFIG="$ROOT_DIR/config_examples/default_config.yaml"
POWER_CONFIG="$BIN_DIR/power.yaml"

SIM_CYCLES="${1:-12000}"
DIMX="${2:-8}"
DIMY="${3:-8}"

CHIPS=4
WARMUP=1000

SNN_TS=500
SNN_TH=1.0
SNN_LEAK=0.9
SNN_WEIGHT=0.30

# chip-specific behavior
# sources (0,1): self-driven firing, both target chip2
BIAS0=0.20; FANOUT0=3; TARGET0=2
BIAS1=0.20; FANOUT1=3; TARGET1=2
# relay (2): no self-bias, should fire only after receiving from chip0/1
BIAS2=0.00; FANOUT2=2; TARGET2=3
# sink (3): receive only
BIAS3=0.00; FANOUT3=0; TARGET3=-1

OUTDIR="$ROOT_DIR/results/snn_live_strong_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$OUTDIR/run"
INBOX_DIR="$RUN_DIR/inbox"
mkdir -p "$INBOX_DIR"

EMPTY_TABLE="$OUTDIR/empty_traffic_table.txt"
cat > "$EMPTY_TABLE" <<'EOF'
% empty traffic table for live SNN strong-interaction run
EOF

for c in 0 1 2 3; do
    : > "$INBOX_DIR/chip${c}_in.txt"
done

echo "======================================================="
echo "  SNN Live Strong Interaction (4 chips, inbox mode)"
echo "======================================================="
echo "Results dir : $OUTDIR"
echo "Sim cycles  : $SIM_CYCLES (+1000 reset)"
echo "Mesh dim    : ${DIMX}x${DIMY} per chip"
echo "Graph       : chip0->chip2, chip1->chip2, chip2->chip3"
echo ""

pids=()

launch_chip() {
    local chip_id="$1"
    local bias="$2"
    local fanout="$3"
    local target="$4"
    local seed="$5"
    local log="$RUN_DIR/chip${chip_id}.log"

    (
        cd "$BIN_DIR"
        exec "$NOXIM" \
            -config "$CONFIG" \
            -power "$POWER_CONFIG" \
            -dimx "$DIMX" -dimy "$DIMY" \
            -chips "$CHIPS" \
            -chip_id "$chip_id" \
            -in_fifo "$INBOX_DIR/chip${chip_id}_in.txt" \
            -out_fifo "$INBOX_DIR" \
            -sim "$SIM_CYCLES" \
            -warmup "$WARMUP" \
            -seed "$seed" \
            -traffic table "$EMPTY_TABLE" \
            -snn_mode \
            -snn_ts_cycles "$SNN_TS" \
            -snn_threshold "$SNN_TH" \
            -snn_leak "$SNN_LEAK" \
            -snn_weight "$SNN_WEIGHT" \
            -snn_bias "$bias" \
            -snn_fanout "$fanout" \
            -snn_target_chip "$target"
    ) > "$log" 2>&1 &

    pids+=("$!")
}

launch_chip 0 "$BIAS0" "$FANOUT0" "$TARGET0" 100
launch_chip 1 "$BIAS1" "$FANOUT1" "$TARGET1" 101
launch_chip 2 "$BIAS2" "$FANOUT2" "$TARGET2" 102
launch_chip 3 "$BIAS3" "$FANOUT3" "$TARGET3" 103

echo "Launched chips: ${pids[*]}"

exit_code=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        rc=$?
        if [[ "$exit_code" -eq 0 ]]; then
            exit_code="$rc"
        fi
    fi
done

extract_stat() {
    local log="$1"
    local key="$2"
    grep "$key" "$log" | grep -oP '\d+' | head -1 || true
}

SUMMARY_CSV="$OUTDIR/summary.csv"
echo "chip,tx_records,parsed_in_records,rx_flits" > "$SUMMARY_CSV"

echo ""
echo "------- FileIO Summary -------"
for chip in 0 1 2 3; do
    log="$RUN_DIR/chip${chip}.log"
    tx="$(extract_stat "$log" "Packets written to out_fifo")"
    parsed="$(extract_stat "$log" "Packet records parsed from in_fifo")"
    rx="$(extract_stat "$log" "Flits read from in_fifo and injected")"
    tx="${tx:-0}"; parsed="${parsed:-0}"; rx="${rx:-0}"
    echo "chip${chip}: tx_records=${tx} parsed_in_records=${parsed} rx_flits=${rx}"
    echo "${chip},${tx},${parsed},${rx}" >> "$SUMMARY_CSV"
done

REPORT="$OUTDIR/interaction_validation_report.txt"
{
    echo "SNN Live Strong Interaction Validation"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Outdir: $OUTDIR"
    echo ""
    echo "Expected interaction chain:"
    echo "  chip0/chip1 (bias>0) -> chip2 (bias=0 relay) -> chip3 (sink)"
    echo ""

    tx0=$(awk -F, '$1=="0"{print $2}' "$SUMMARY_CSV")
    tx1=$(awk -F, '$1=="1"{print $2}' "$SUMMARY_CSV")
    tx2=$(awk -F, '$1=="2"{print $2}' "$SUMMARY_CSV")
    parsed2=$(awk -F, '$1=="2"{print $3}' "$SUMMARY_CSV")
    parsed3=$(awk -F, '$1=="3"{print $3}' "$SUMMARY_CSV")

    echo "Observed counters:"
    echo "  chip0 tx_records       = ${tx0}"
    echo "  chip1 tx_records       = ${tx1}"
    echo "  chip2 parsed_in_records= ${parsed2}"
    echo "  chip2 tx_records       = ${tx2}"
    echo "  chip3 parsed_in_records= ${parsed3}"
    echo ""

    pass=1
    [[ "${tx0}" -gt 0 ]] || pass=0
    [[ "${tx1}" -gt 0 ]] || pass=0
    [[ "${parsed2}" -gt 0 ]] || pass=0
    [[ "${tx2}" -gt 0 ]] || pass=0
    [[ "${parsed3}" -gt 0 ]] || pass=0

    if [[ "$pass" -eq 1 ]]; then
        echo "RESULT: PASS"
        echo "Meaning: runtime spikes from chip0/1 reached chip2 and triggered further forwarding to chip3."
    else
        echo "RESULT: CHECK_NEEDED"
        echo "Some expected counters are zero; inspect chip logs in $RUN_DIR."
    fi
} > "$REPORT"

echo ""
echo "Summary CSV : $SUMMARY_CSV"
echo "Validation  : $REPORT"
echo "Chip logs   : $RUN_DIR/chip*.log"
echo "Inbox files : $INBOX_DIR/chip*_in.txt"

if [[ "$exit_code" -ne 0 ]]; then
    echo "WARNING: non-zero chip exit code detected: $exit_code"
    exit "$exit_code"
fi

