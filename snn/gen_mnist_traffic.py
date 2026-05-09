#!/usr/bin/env python3
"""
Generate Noxim traffic table from real SNN inference on MNIST.

Pipeline:
  1. Load trained ANN weights (W1, b1, W2, b2)
  2. Run SNN inference with rate coding (T timesteps)
  3. Record inter-chip spike events as (src_chip, dst_chip, src_pe, dst_pe, cycle)
  4. Write traffic table for Noxim

Chip mapping (3 chips, all DIMxDIM NoC):
  chip 0: input layer  (784 neurons → DIM*DIM PEs, ~784/(DIM*DIM) neurons/PE)
  chip 1: hidden layer (256 neurons → DIM*DIM PEs, ~256/(DIM*DIM) neurons/PE)
  chip 2: output layer (10  neurons → PE 0..9, rest idle)

Usage:
  python3 gen_mnist_traffic.py [num_images] [timesteps] [interval] [dim] [outfile] [start_idx]

Defaults:
  num_images = 10        <- keep small so Noxim sim cycles stay manageable
  timesteps  = 8
  interval   = 500       <- cycles between timesteps
  dim        = 4         <- NoC mesh dimension (4x4=16 PEs per chip)
  outfile    = ../traffic_tables/mnist_snn_traffic.txt
  start_idx  = 0
"""

import os, sys
import numpy as np

# ---------- paths ----------
BASE        = os.path.dirname(os.path.abspath(__file__))
WEIGHTS_DIR = os.path.join(BASE, 'weights')
DATA_DIR    = os.path.join(BASE, 'data')

# ---------- args ----------
num_images = int(sys.argv[1])   if len(sys.argv) > 1 else 10
timesteps  = int(sys.argv[2])   if len(sys.argv) > 2 else 8
interval   = int(sys.argv[3])   if len(sys.argv) > 3 else 500
dim        = int(sys.argv[4])   if len(sys.argv) > 4 else 4   # NoC mesh dim
outfile    = sys.argv[5]        if len(sys.argv) > 5 else \
             os.path.join(BASE, '..', 'traffic_tables', 'mnist_snn_traffic.txt')
start_idx  = int(sys.argv[6])   if len(sys.argv) > 6 else 0

num_pe      = dim * dim          # PEs per chip
n_input     = 784
n_hidden    = 256
n_output    = 10
# neurons per PE (ceiling division, last PE may have fewer)
npe_input  = (n_input  + num_pe - 1) // num_pe   # ceil(784/16) = 49
npe_hidden = (n_hidden + num_pe - 1) // num_pe   # ceil(256/16) = 16

def neuron_to_pe(neuron_id, neurons_per_pe):
    """Map a neuron index to its PE index."""
    return neuron_id // neurons_per_pe

os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)

# ---------- load weights ----------
W1 = np.load(os.path.join(WEIGHTS_DIR, 'W1.npy'))  # (784, 256)
b1 = np.load(os.path.join(WEIGHTS_DIR, 'b1.npy'))  # (256,)
W2 = np.load(os.path.join(WEIGHTS_DIR, 'W2.npy'))  # (256, 10)
b2 = np.load(os.path.join(WEIGHTS_DIR, 'b2.npy'))  # (10,)

# ---------- load data ----------
X_te = np.load(os.path.join(DATA_DIR, 'test_X.npy'))   # (N, 784)
y_te = np.load(os.path.join(DATA_DIR, 'test_y.npy'))
if start_idx < 0 or start_idx >= len(X_te):
    raise ValueError(f"start_idx out of range: {start_idx}, dataset size={len(X_te)}")
end_idx = min(start_idx + num_images, len(X_te))
X    = X_te[start_idx:end_idx]
y    = y_te[start_idx:end_idx]
num_images = len(X)

# ---------- ANN forward (get continuous activations) ----------
def relu(x):
    return np.maximum(0, x)

def ann_forward(x):
    """Single sample forward pass, returns (a1, a2) activations."""
    z1 = x @ W1 + b1        # (256,)
    a1 = relu(z1)            # (256,)  hidden layer activation
    z2 = a1 @ W2 + b2        # (10,)
    a2 = np.exp(z2 - z2.max())
    a2 /= a2.sum()           # (10,)  output softmax
    return a1, a2

# ---------- rate coding: normalize activations to [0,1] ----------
# Pre-compute all activations to find global max for normalization
print(f"Running ANN forward pass on {num_images} images (start_idx={start_idx})...")
all_a1 = []
all_a2 = []
predictions = []
for i in range(num_images):
    a1, a2 = ann_forward(X[i])
    all_a1.append(a1)
    all_a2.append(a2)
    predictions.append(int(a2.argmax()))

all_a1 = np.array(all_a1)   # (num_images, 256)
all_a2 = np.array(all_a2)   # (num_images, 10)

# Normalize to [0, 1] so values can be used as spike probabilities
a1_max = all_a1.max() if all_a1.max() > 0 else 1.0
a2_max = all_a2.max() if all_a2.max() > 0 else 1.0
spike_prob_h = all_a1 / a1_max   # (num_images, 256) hidden layer spike probs
spike_prob_o = all_a2 / a2_max   # (num_images, 10)  output layer spike probs

# Print prediction results
correct = sum(predictions[i] == int(y[i]) for i in range(num_images))
print(f"ANN predictions (label -> pred):")
for i in range(num_images):
    mark = 'OK' if predictions[i] == int(y[i]) else 'WRONG'
    print(f"  img {i:3d}: label={y[i]}  pred={predictions[i]}  {mark}")
print(f"Accuracy: {correct}/{num_images} = {correct/num_images*100:.1f}%")

# ---------- SNN inference + traffic recording ----------
rng     = np.random.default_rng(42)
entries = []   # (src_chip, dst_chip, src_pe, dst_pe, inject_cycle)

print(f"Simulating SNN inference: {num_images} images x {timesteps} timesteps...")

for img_idx in range(num_images):
    p_h = spike_prob_h[img_idx]   # (256,)
    p_o = spike_prob_o[img_idx]   # (10,)

    for t in range(timesteps):
        inject_cycle = (img_idx * timesteps + t + 1) * interval

        # --- chip0 -> chip1: input spikes drive hidden layer ---
        # Input spikes: pixel intensity as Poisson spike probability
        input_spikes  = (rng.random(n_input) < X[img_idx]).astype(int)
        firing_neurons = np.where(input_spikes)[0]

        for nid in firing_neurons:
            src_pe = neuron_to_pe(nid, npe_input)        # map neuron → PE (0-15)
            # Weight-proportional target selection: sample dst proportional to W1[nid,:]
            pos_w = np.maximum(0.0, W1[nid])
            total = pos_w.sum()
            if total == 0:
                continue
            dst_nid = int(rng.choice(n_hidden, p=pos_w / total))
            dst_pe  = neuron_to_pe(dst_nid, npe_hidden)  # map hidden neuron → PE
            entries.append((0, 1, src_pe, dst_pe, inject_cycle))

        # --- chip1 -> chip2: hidden spikes drive output layer ---
        hidden_spikes  = (rng.random(n_hidden) < p_h).astype(int)
        firing_hidden  = np.where(hidden_spikes)[0]

        for nid in firing_hidden:
            src_pe  = neuron_to_pe(nid, npe_hidden)       # map hidden neuron → PE
            # Weight-proportional target selection: sample dst proportional to W2[nid,:]
            pos_w = np.maximum(0.0, W2[nid])
            total = pos_w.sum()
            if total == 0:
                continue
            dst_nid = int(rng.choice(n_output, p=pos_w / total))
            if dst_nid >= num_pe:
                continue                                  # safety: ignore if out of range
            entries.append((1, 2, src_pe, dst_nid, inject_cycle))

# ---------- write traffic table ----------
# Sort by inject_cycle for Noxim
entries.sort(key=lambda e: e[4])

with open(outfile, 'w') as f:
    f.write("# Noxim traffic table generated from MNIST SNN inference\n")
    f.write(f"# num_images={num_images}, timesteps={timesteps}, interval={interval}, start_idx={start_idx}\n")
    f.write(f"# chip mapping: 0=input(784), 1=hidden(256), 2=output(10)\n")
    f.write(f"# {len(entries)} total spike events\n")
    f.write("# src_chip  dst_chip  src_pe  dst_pe  inject_cycle\n")
    for e in entries:
        f.write(f"{e[0]}  {e[1]}  {e[2]}  {e[3]}  {e[4]}\n")

# ---------- stats ----------
total   = len(entries)
c01     = sum(1 for e in entries if e[0] == 0)
c12     = sum(1 for e in entries if e[0] == 1)
avg_per_img = total / num_images
print(f"\nDone.")
print(f"  Total spike events : {total}")
print(f"  chip0->chip1       : {c01}  ({c01/total*100:.1f}%)")
print(f"  chip1->chip2       : {c12}  ({c12/total*100:.1f}%)")
print(f"  Avg events/image   : {avg_per_img:.1f}")
max_cycle = max(e[4] for e in entries) if entries else 0
print(f"  Saved to: {outfile}")
print(f"\nNoxim run hint:")
print(f"  python3 gen_mnist_traffic.py -> then run:")
sim_cycles = max_cycle + 2000
print(f"  ./noxim -config ../config_examples/default_config.yaml \\")
print(f"    -dimx {dim} -dimy {dim} -chips 3 -sim {sim_cycles} \\")
print(f"    -cross_traffic {os.path.abspath(outfile)}")
