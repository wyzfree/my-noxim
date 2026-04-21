#!/usr/bin/env python3
"""
Evaluate chip-side MNIST predictions from chip1->chip2 spike records.

Prediction rule per image:
  Count output spikes at dst_pe 0..9 across all timesteps, then argmax.
"""

import os
import sys
import numpy as np


def usage() -> None:
    print(
        "Usage: python eval_mnist_chip_pred.py "
        "<chip1_out.txt> <num_images> <timesteps> <interval> <start_idx>"
    )


def main() -> int:
    if len(sys.argv) < 6:
        usage()
        return 1

    chip1_out = sys.argv[1]
    num_images = int(sys.argv[2])
    timesteps = int(sys.argv[3])
    interval = int(sys.argv[4])
    start_idx = int(sys.argv[5])

    base = os.path.dirname(os.path.abspath(__file__))
    y_path = os.path.join(base, "data", "test_y.npy")
    y_all = np.load(y_path)

    if start_idx < 0 or start_idx + num_images > len(y_all):
        print(
            f"ERROR: label range out of bounds. start_idx={start_idx}, "
            f"num_images={num_images}, dataset={len(y_all)}"
        )
        return 1

    true_labels = y_all[start_idx:start_idx + num_images].astype(int)
    scores = np.zeros((num_images, 10), dtype=np.int64)

    with open(chip1_out, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            toks = line.split()
            if len(toks) < 5:
                continue
            src_chip = int(toks[0])
            dst_chip = int(toks[1])
            dst_pe = int(toks[3])
            inject_cycle = int(toks[4])

            if src_chip != 1 or dst_chip != 2:
                continue
            if dst_pe < 0 or dst_pe > 9:
                continue
            if inject_cycle <= 0 or inject_cycle % interval != 0:
                continue

            step_idx = inject_cycle // interval - 1
            img_idx = step_idx // timesteps
            if 0 <= img_idx < num_images:
                scores[img_idx, dst_pe] += 1

    preds = []
    total_nonzero = 0
    correct = 0

    print("Image  True  Pred  TopCount  TotalOutSpikes")
    for i in range(num_images):
        total = int(scores[i].sum())
        if total > 0:
            pred = int(scores[i].argmax())
            top = int(scores[i, pred])
            total_nonzero += 1
        else:
            pred = -1
            top = 0
        preds.append(pred)
        if pred == int(true_labels[i]):
            correct += 1
        print(f"{i:5d}  {int(true_labels[i]):4d}  {pred:4d}  {top:8d}  {total:14d}")

    acc = correct / num_images if num_images > 0 else 0.0
    print("")
    print(f"Coverage (images with any output spikes): {total_nonzero}/{num_images}")
    print(f"Accuracy: {correct}/{num_images} = {acc * 100:.2f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

