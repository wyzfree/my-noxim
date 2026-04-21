# Experiment Setup Template

## Table A. Platform and Runtime Environment

| Item | Value / Description |
|---|---|
| Simulator | Noxim (multi-process FileIO mode) |
| Code branch / commit | `<fill_commit_hash>` |
| OS / kernel | `<fill_os_info>` |
| Compiler | `g++` `<fill_version>` |
| Python env | `paper` (numpy required) |
| Random seed policy | `numpy.default_rng(42)` (traffic generation) |
| Execution mode | 3 parallel processes (`chip0`, `chip1`, `chip2`) |

## Table B. Network-on-Chip Configuration

| Parameter | Symbol | Value |
|---|---|---|
| Mesh dimension per chip | `dim` | `<e.g., 4x4>` |
| Number of chips | `N_chip` | `3` |
| Clock period | `T_clk` | `<from YAML>` |
| Reset cycles | `N_reset` | `<e.g., 1000>` |
| Warmup cycles | `N_warmup` | `<e.g., 1000>` |
| Simulation cycles | `N_sim` | `max_inject_cycle + sim_margin` |
| Routing algorithm | - | `<e.g., XY>` |
| Selection strategy | - | `<e.g., RANDOM>` |
| Buffer depth | - | `<from YAML/CLI>` |

## Table C. Task and Encoding Configuration (MNIST-SNN)

| Parameter | Symbol | Value |
|---|---|---|
| Dataset | - | MNIST test set |
| Start index | `start_idx` | `<fill>` |
| Number of images | `N_img` | `<fill>` |
| Timesteps per image | `T` | `<fill>` |
| Timestep interval (cycles) | `I` | `<fill>` |
| Input neurons | `N_in` | `784` |
| Hidden neurons | `N_h` | `256` |
| Output neurons | `N_out` | `10` |
| Coding method | - | rate/Poisson |
| Weight files | - | `W1,b1,W2,b2` |

## Table D. Chip Mapping

| Chip ID | Functional role | Neuron mapping |
|---|---|---|
| chip0 | Input layer | 784 neurons mapped to `dim*dim` PEs |
| chip1 | Hidden layer | 256 neurons mapped to `dim*dim` PEs |
| chip2 | Output layer | class neurons `0..9` mapped to PE `0..9` |

## Table E. Reported Metrics

| Category | Metric | Definition |
|---|---|---|
| Communication correctness | TX/RX consistency | Compare measured packet/flit counts with traffic-derived expectations |
| Network performance | Throughput | flits per cycle |
| Network performance | Average delay | cycles per packet/flit statistic reported by Noxim |
| Energy (optional) | Total energy | from simulator log |
| Task quality | Per-image prediction | argmax over chip1->chip2 output spike counts (class 0..9) |
| Task quality | Accuracy | `#correct / N_img` |
| Task quality | Coverage | fraction of images with non-zero output spikes |

## Reproducibility Checklist

- Command used:
  - `bash scripts/run_snn_mnist_real.sh <num_images> <timesteps> <interval> <dim> <sim_margin> <start_idx>`
- Saved artifacts:
  - runtime traffic file
  - `chip0.log`, `chip1.log`, `chip2.log`
  - `chip0_out.txt`, `chip1_out.txt`, `chip2_out.txt`
  - `chip_eval.log`
- Fixed seed and exact config filenames recorded in appendix.

## Optional LaTeX Snippet (Directly Usable)

```latex
\begin{table}[t]
\centering
\caption{Key experimental parameters.}
\label{tab:exp_params}
\begin{tabular}{ll}
\hline
Parameter & Value \\
\hline
NoC topology & 2D Mesh (per chip) \\
Chips & 3 (input/hidden/output) \\
Images ($N_{img}$) & \texttt{<fill>} \\
Timesteps ($T$) & \texttt{<fill>} \\
Interval ($I$) & \texttt{<fill>} cycles \\
Dimension ($dim$) & \texttt{<fill>} \\
Simulation cycles & $\max(inject\_cycle)+\texttt{sim\_margin}$ \\
\hline
\end{tabular}
\end{table}
```
