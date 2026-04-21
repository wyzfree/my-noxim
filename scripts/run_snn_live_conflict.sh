#!/bin/bash
# Live SNN conflict demo (multi-process + FileIO inbox mode).
# No precomputed cross_traffic table.
#
# Conflict-heavy graph (default):
#   chip0 -> chip2
#   chip1 -> chip2
#   chip2 -> chip0
#   chip3 -> chip0
#
# Therefore:
#   chip2_in.txt is written by chip0 and chip1 (multi-writer).
#   chip0_in.txt is written by chip2 and chip3 (multi-writer).
#   chip0/chip2 also read while others append (read-write concurrency).

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
# 0,1 drive chip2
BIAS0=0.18; FANOUT0=3; TARGET0=2
BIAS1=0.20; FANOUT1=3; TARGET1=2
# 2 relays back to chip0 (primarily input-driven)
BIAS2=0.00; FANOUT2=2; TARGET2=0
# 3 independently drives chip0
BIAS3=0.18; FANOUT3=2; TARGET3=0

OUTDIR="$ROOT_DIR/results/snn_live_conflict_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$OUTDIR/run"
INBOX_DIR="$RUN_DIR/inbox"
mkdir -p "$INBOX_DIR"

EMPTY_TABLE="$OUTDIR/empty_traffic_table.txt"
cat > "$EMPTY_TABLE" <<'EOF'
% empty traffic table for live SNN conflict run
EOF

for c in 0 1 2 3; do
    : > "$INBOX_DIR/chip${c}_in.txt"
done

echo "======================================================="
echo "  SNN Live Conflict Demo (4 chips, inbox mode)"
echo "======================================================="
echo "Results dir : $OUTDIR"
echo "Sim cycles  : $SIM_CYCLES (+1000 reset)"
echo "Mesh dim    : ${DIMX}x${DIMY} per chip"
echo "Graph       : 0->2, 1->2, 2->0, 3->0"
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

launch_chip 0 "$BIAS0" "$FANOUT0" "$TARGET0" 200
launch_chip 1 "$BIAS1" "$FANOUT1" "$TARGET1" 201
launch_chip 2 "$BIAS2" "$FANOUT2" "$TARGET2" 202
launch_chip 3 "$BIAS3" "$FANOUT3" "$TARGET3" 203

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

SRC_COUNT0="$OUTDIR/chip0_in_src_counts.txt"
SRC_COUNT2="$OUTDIR/chip2_in_src_counts.txt"
awk 'NF>=1 {c[$1]++} END {for(k in c) print k, c[k]}' "$INBOX_DIR/chip0_in.txt" | sort -n > "$SRC_COUNT0"
awk 'NF>=1 {c[$1]++} END {for(k in c) print k, c[k]}' "$INBOX_DIR/chip2_in.txt" | sort -n > "$SRC_COUNT2"

REPORT="$OUTDIR/interaction_validation_report.txt"
{
    echo "SNN Live Conflict Validation"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Outdir: $OUTDIR"
    echo ""
    echo "Expected conflict graph: 0->2, 1->2, 2->0, 3->0"
    echo ""

    tx0=$(awk -F, '$1=="0"{print $2}' "$SUMMARY_CSV")
    tx1=$(awk -F, '$1=="1"{print $2}' "$SUMMARY_CSV")
    tx2=$(awk -F, '$1=="2"{print $2}' "$SUMMARY_CSV")
    tx3=$(awk -F, '$1=="3"{print $2}' "$SUMMARY_CSV")
    parsed0=$(awk -F, '$1=="0"{print $3}' "$SUMMARY_CSV")
    parsed2=$(awk -F, '$1=="2"{print $3}' "$SUMMARY_CSV")

    echo "Observed counters:"
    echo "  chip0 tx_records       = ${tx0}"
    echo "  chip1 tx_records       = ${tx1}"
    echo "  chip2 tx_records       = ${tx2}"
    echo "  chip3 tx_records       = ${tx3}"
    echo "  chip0 parsed_in_records= ${parsed0}"
    echo "  chip2 parsed_in_records= ${parsed2}"
    echo ""
    echo "chip0_in source distribution (expect src 2 and 3):"
    cat "$SRC_COUNT0"
    echo ""
    echo "chip2_in source distribution (expect src 0 and 1):"
    cat "$SRC_COUNT2"
    echo ""

    pass=1
    [[ "${tx0}" -gt 0 ]] || pass=0
    [[ "${tx1}" -gt 0 ]] || pass=0
    [[ "${tx2}" -gt 0 ]] || pass=0
    [[ "${tx3}" -gt 0 ]] || pass=0
    [[ "${parsed0}" -gt 0 ]] || pass=0
    [[ "${parsed2}" -gt 0 ]] || pass=0
    grep -q '^2 ' "$SRC_COUNT0" || pass=0
    grep -q '^3 ' "$SRC_COUNT0" || pass=0
    grep -q '^0 ' "$SRC_COUNT2" || pass=0
    grep -q '^1 ' "$SRC_COUNT2" || pass=0

    if [[ "$pass" -eq 1 ]]; then
        echo "RESULT: PASS"
        echo "Meaning: both chip0_in and chip2_in are true multi-writer inbox files under live runtime generation."
    else
        echo "RESULT: CHECK_NEEDED"
        echo "Some expected counters or multi-writer signatures are missing."
    fi
} > "$REPORT"

echo ""
echo "Summary CSV : $SUMMARY_CSV"
echo "Validation  : $REPORT"
echo "chip0_in src: $SRC_COUNT0"
echo "chip2_in src: $SRC_COUNT2"
echo "Chip logs   : $RUN_DIR/chip*.log"
echo "Inbox files : $INBOX_DIR/chip*_in.txt"

if [[ "$exit_code" -ne 0 ]]; then
    echo "WARNING: non-zero chip exit code detected: $exit_code"
    exit "$exit_code"
fi

