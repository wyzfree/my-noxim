#!/usr/bin/env python3
"""
Generate fair cross-traffic entries with an exact target count.

Usage:
  python3 gen_fair_cross_traffic.py <num_chips> <num_pe> <entries> [timesteps] [interval] [outfile] [seed]

Notes:
  - Output format:
      src_chip  dst_chip  src_pe  dst_pe  inject_cycle
  - For num_chips == 1, dst_chip is always 0 (self-injection via ChipIO).
  - For num_chips > 1, dst_chip is always chosen != src_chip.
"""

import random
import sys


def rand_dst_chip(num_chips: int, src_chip: int) -> int:
    if num_chips <= 1:
        return 0
    dst = random.randrange(num_chips - 1)
    return dst + 1 if dst >= src_chip else dst


def rand_dst_pe(num_pe: int, src_pe: int) -> int:
    if num_pe <= 1:
        return 0
    dst = random.randrange(num_pe - 1)
    return dst + 1 if dst >= src_pe else dst


def main() -> int:
    num_chips = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    num_pe = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    entries = int(sys.argv[3]) if len(sys.argv) > 3 else 256
    timesteps = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    interval = int(sys.argv[5]) if len(sys.argv) > 5 else 2000
    outfile = (
        sys.argv[6]
        if len(sys.argv) > 6
        else f"fair_cross_{num_chips}c_{num_pe}pe_{entries}e.txt"
    )
    seed = int(sys.argv[7]) if len(sys.argv) > 7 else 42

    if num_chips < 1 or num_pe < 1 or entries < 0 or timesteps < 1 or interval < 1:
        raise ValueError("Invalid arguments: chips/pe/timesteps/interval must be positive, entries >= 0.")

    random.seed(seed)

    inject_slots = [interval * (t + 1) for t in range(timesteps)]
    rows = []
    for _ in range(entries):
        src_chip = random.randrange(num_chips)
        dst_chip = rand_dst_chip(num_chips, src_chip)
        src_pe = random.randrange(num_pe)
        dst_pe = rand_dst_pe(num_pe, src_pe)
        inject_cycle = random.choice(inject_slots)
        rows.append((src_chip, dst_chip, src_pe, dst_pe, inject_cycle))

    rows.sort(key=lambda r: r[4])

    with open(outfile, "w", encoding="utf-8") as f:
        f.write("# src_chip dst_chip src_pe dst_pe inject_cycle\n")
        f.write(
            f"# entries={entries} chips={num_chips} pe_per_chip={num_pe} "
            f"timesteps={timesteps} interval={interval} seed={seed}\n"
        )
        for r in rows:
            f.write(f"{r[0]} {r[1]} {r[2]} {r[3]} {r[4]}\n")

    print(f"Generated {entries} fair entries -> {outfile} (seed={seed})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

