#!/usr/bin/env python3
"""
Generate cross-chip traffic table for multi-chip SNN simulation.
Models a feed-forward SNN: chip0 -> chip1 -> ... -> chip(N-1)

Usage:
    python3 gen_cross_traffic.py <num_chips> <num_pe> [timesteps] [interval] [sparsity] [outfile] [seed]

Defaults:
    timesteps = 5
    interval  = 2000  (cycles between timesteps)
    sparsity  = 0.15
    outfile   = cross_traffic_<num_chips>chips_<num_pe>pe.txt
    seed      = 42
"""
import sys
import random

num_chips = int(sys.argv[1])   if len(sys.argv) > 1 else 4
num_pe    = int(sys.argv[2])   if len(sys.argv) > 2 else 64
timesteps = int(sys.argv[3])   if len(sys.argv) > 3 else 5
interval  = int(sys.argv[4])   if len(sys.argv) > 4 else 2000
sparsity  = float(sys.argv[5]) if len(sys.argv) > 5 else 0.15
outfile   = sys.argv[6]        if len(sys.argv) > 6 else \
            f"cross_traffic_{num_chips}chips_{num_pe}pe.txt"
seed      = int(sys.argv[7])   if len(sys.argv) > 7 else 42

random.seed(seed)

entries = []
for t in range(timesteps):
    inject_cycle = interval + t * interval
    for src_chip in range(num_chips - 1):
        dst_chip = src_chip + 1
        for src_pe in range(num_pe):
            if random.random() < sparsity:
                dst_pe = random.randint(0, num_pe - 1)
                entries.append((src_chip, dst_chip, src_pe, dst_pe, inject_cycle))

with open(outfile, "w") as f:
    f.write(f"# src_chip  dst_chip  src_pe  dst_pe  inject_cycle\n")
    f.write(f"# {len(entries)} entries, {num_chips} chips x {num_pe} PE, {timesteps} timesteps\n")
    f.write(f"# seed={seed}, sparsity={sparsity}, interval={interval}\n")
    for e in entries:
        f.write(f"{e[0]}  {e[1]}  {e[2]}  {e[3]}  {e[4]}\n")

print(f"Generated {len(entries)} entries -> {outfile} (seed={seed})")
