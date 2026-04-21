# Method Pipeline (Paper Style, English)

We implement an MNIST-driven SNN simulation pipeline for a multi-chip NoC platform. The key design principle is to decouple neural activity generation from inter-chip transport simulation, while regenerating task traffic at runtime for each experiment to ensure realistic and reproducible inputs.

First, the framework loads MNIST test samples and trained network parameters (W1/b1/W2/b2). Experimental slices are configured by `num_images`, `timesteps`, `interval`, `dim`, and `start_idx`. Next, a software front-end performs rate/Poisson spike encoding over time: at each timestep, pixel intensities are converted into spike probabilities, then transformed into cross-chip events from input to hidden layer and from hidden to output layer. Events are serialized as `(src_chip, dst_chip, src_pe, dst_pe, inject_cycle)` records, forming a runtime traffic file.

During NoC simulation, we run three chip processes (chip0/chip1/chip2) in parallel and exchange traffic via FileIO. The sender filters records by local source chip and writes them to `out_fifo`; the receiver continuously reads remote records and injects them into the local mesh at the specified `inject_cycle`. To eliminate data loss caused by wall-clock skew across processes, the current implementation uses a “pre-dump records + cycle-accurate injection” policy.

After simulation, two-level validation is performed. Level-1 validates communication consistency by checking whether transmitted packet counts (chip0/chip1) and received flit counts (chip1/chip2) match theoretical expectations. Level-2 validates task correctness by parsing chip1→chip2 output spikes, accumulating class-wise counts for `dst_pe=0..9` within each image time window, assigning prediction via argmax, and comparing with ground-truth labels to compute accuracy.

This pipeline provides three benefits: (1) realistic and controllable task inputs with reproducibility, (2) explicit NoC-level observability (throughput, delay, and TX/RX consistency), and (3) direct task-level metrics (per-sample prediction and overall accuracy) suitable for architecture-level comparison studies.
