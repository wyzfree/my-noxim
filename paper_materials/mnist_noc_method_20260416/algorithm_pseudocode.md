# Algorithm Boxes / Pseudocode

## Algorithm 1: Runtime MNIST Traffic Generation

```text
Input: test_X, test_y, W1, b1, W2, b2,
       num_images, timesteps, interval, dim, start_idx
Output: traffic_records

1: Select samples X = test_X[start_idx : start_idx + num_images]
2: For each sample x in X:
3:     Compute ANN activations a1, a2
4: Normalize activations to spike probabilities
5: For image index i in [0, num_images-1]:
6:     For timestep t in [0, timesteps-1]:
7:         inject_cycle <- (i * timesteps + t + 1) * interval
8:         Sample input spikes from pixel probabilities
9:         Map firing input neurons to src_pe on chip0
10:        Select hidden targets (positive W1 connections), map to dst_pe on chip1
11:        Append (0,1,src_pe,dst_pe,inject_cycle)
12:        Sample hidden spikes from hidden probabilities
13:        Map hidden neurons to src_pe on chip1
14:        Select output targets (positive W2 connections), dst_pe in [0..9] on chip2
15:        Append (1,2,src_pe,dst_pe,inject_cycle)
16: Sort all records by inject_cycle
17: Write runtime traffic file
```

## Algorithm 2: Multi-Process NoC Simulation with FileIO

```text
Input: runtime_traffic, config, sim_cycles
Output: chip logs, fifo files, communication stats

1: Launch chip0/chip1/chip2 as separate noxim processes
2: For each chip process c:
3:     crossOutThread loads records with src_chip == c
4:     Write records to out_fifo (keeping inject_cycle)
5: For each receiver process:
6:     fileReaderThread reads in_fifo continuously
7:     Parse records and enqueue pending flits by inject_cycle
8:     At each cycle, inject due flits into boundary ports
9: Run all processes until sim_cycles
10: Collect TX packet counts and RX flit counts from logs
11: Compare with expected counts from runtime_traffic
```

## Algorithm 3: Chip-Side Prediction and Accuracy Evaluation

```text
Input: chip1_out_records (1->2), test_y, num_images, timesteps, interval, start_idx
Output: per-image predictions, overall accuracy

1: Initialize score matrix S[num_images][10] = 0
2: For each record r in chip1_out_records:
3:     If r is not (src_chip=1, dst_chip=2), continue
4:     Derive image index:
5:         step_idx <- r.inject_cycle / interval - 1
6:         img_idx  <- step_idx / timesteps
7:     If img_idx in valid range and dst_pe in [0..9]:
8:         S[img_idx][dst_pe] += 1
9: For each image i:
10:    pred[i] <- argmax_k S[i][k]
11:    true[i] <- test_y[start_idx + i]
12: Compute accuracy = mean(pred[i] == true[i])
13: Report per-image (true, pred, top_count, total_spikes) and overall accuracy
```
