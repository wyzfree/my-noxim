# Graduation Checklist (Noxim Parallel Optimization)

This checklist is tailored to the thesis goal:
- Parallel optimization for NoC simulation
- Intra-chip optimization + multi-chip support
- Evidence that improved Noxim can handle larger modern workloads

## A. Must-Have Deliverables (Minimum for Graduation)

### A1. Problem Definition and Baseline
- [ ] State baseline clearly: original Noxim execution model and limitations.
- [ ] Define bottlenecks (e.g., event scheduling overhead, single-process constraints, cross-chip simulation limits).
- [ ] Freeze one baseline version/commit for fair comparison.

### A2. Multi-Chip Parallel Support (Already partly done)
- [x] Multi-process FileIO communication path implemented and running.
- [x] Cross-chip correctness checks (TX/RX expected-count consistency).
- [ ] Document design choices: why FileIO, synchronization policy, ordering guarantees, limitations.

### A3. Intra-Chip Parallel Optimization (Critical for topic match)
- [ ] Implement at least one intra-chip optimization (not only inter-chip split).
- [ ] Keep feature flag / switch to compare before vs after.
- [ ] Provide correctness parity tests after optimization.

### A4. Quantitative Evaluation
- [ ] Report runtime/speedup for multiple scales.
- [ ] Report scaling with chip count (e.g., 1/2/4/8/16/32).
- [ ] Report scaling with per-chip mesh size.
- [ ] Compute speedup and parallel efficiency.
- [ ] Include at least one workload with task semantics (MNIST-SNN) + one synthetic workload.

### A5. Correctness and Reproducibility
- [ ] Traffic consistency checks pass across all key experiments.
- [ ] Task-level output validation (prediction/accuracy pipeline).
- [ ] One-command scripts for reproduction.
- [ ] Record environment, versions, seeds, and command lines.

### A6. Thesis Writing Assets
- [x] Method section drafts (CN/EN).
- [x] Pseudocode draft.
- [x] Experiment setup template.
- [ ] Fill all template values with final numbers.
- [ ] Add result tables/figures + interpretation.

---

## B. Recommended Experiment Matrix

## B1. Performance (Simulator-Centric)
- [ ] Fixed total compute scale, vary chip count.
- [ ] Fixed chip count, vary per-chip dimension.
- [ ] Compare baseline vs optimized runtime.
- [ ] Plot speedup and efficiency curves.

## B2. Communication Integrity
- [ ] For each setting, compare expected vs measured:
  - TX packets per stage
  - RX flits per stage
  - pending queue at end
- [ ] Confirm no record loss in long runs.

## B3. Task-Level (MNIST-SNN)
- [ ] Run multiple `start_idx` windows (not one cherry-picked range).
- [ ] Report mean/std accuracy over windows.
- [ ] Report throughput-delay-energy with task traffic.

---

## C. Suggested Week-by-Week Execution Plan

## Week 1: Stabilize + Baseline Freeze
- [ ] Freeze baseline commit and optimized commit.
- [ ] Run smoke tests on both.
- [ ] Build final reproducible scripts list.

## Week 2: Intra-Chip Optimization Work
- [ ] Implement one intra-chip optimization with switch.
- [ ] Add micro-benchmark for intra-chip path.
- [ ] Verify correctness parity.

## Week 3: Full Benchmark Sweep
- [ ] Run performance matrix.
- [ ] Collect logs and raw CSVs.
- [ ] Generate figures (speedup, efficiency, throughput-delay).

## Week 4: Task Evaluation + Writing
- [ ] Run MNIST windows and aggregate results.
- [ ] Fill method/experiment/result sections.
- [ ] Final consistency check and appendix commands.

---

## D. Paper/Thesis Section Mapping (What supports what)

- Chapter "System Design":
  - FileIO multi-process architecture
  - Cross-chip record/injection mechanism
  - Synchronization policy and rationale

- Chapter "Optimization":
  - Intra-chip optimization method
  - Complexity/overhead discussion

- Chapter "Evaluation":
  - Runtime speedup / parallel efficiency
  - Correctness equivalence checks
  - MNIST task-level metrics

- Appendix:
  - Command lines, config files, seeds, environment
  - Folder structure for logs/results

---

## E. Risk List (High Priority)

- [ ] Risk: only inter-chip parallelization is shown, topic asks intra-chip too.
- [ ] Risk: no strong baseline comparison => contribution appears as feature extension, not optimization.
- [ ] Risk: few test points => weak scalability claim.
- [ ] Risk: correctness only shown on one workload/seed.

Mitigation:
- Add intra-chip optimization switch + A/B test.
- Build fixed benchmark matrix and publish all raw logs.
- Use multiple seeds/start windows for MNIST runs.

---

## F. Definition of Done (Can submit thesis confidently)

- [ ] Inter-chip + intra-chip optimization both implemented.
- [ ] Baseline vs optimized quantitative gains reported.
- [ ] Correctness validated at communication and task levels.
- [ ] Reproducibility guaranteed by scripts + documented settings.
- [ ] Method, experiments, and conclusions are logically aligned with thesis title.

