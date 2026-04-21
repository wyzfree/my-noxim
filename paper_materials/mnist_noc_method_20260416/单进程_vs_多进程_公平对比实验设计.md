# 单进程 vs 多进程（FileIO）公平对比实验设计

## 1. 目标问题
- 问题：多进程方案是否比单进程方案更快？
- 指标：端到端 wall time（秒）。
- 判据：`speedup = T_single / T_multi`。当 `speedup > 1` 时，多进程更快。

## 2. 公平性约束
- 两种模式使用同一份 `cross_traffic` 文件（同一 run 内共享）。
- 参数完全一致：`chips, dimx, dimy, sim, sparsity, target_entries, seed`。
- 关闭 PE 随机注入：`-traffic table empty_traffic_table.txt`。
- 单进程模式：`ChipIO`（一个进程内模拟所有芯片）。
- 多进程模式：`FileIO inbox`（每芯片一个进程，跨进程文件交互）。

## 3. 已实现脚本
- 脚本：`scripts/run_single_vs_multiprocess_fair.sh`
- 输出目录：`results/single_vs_multiprocess_fair_<timestamp>/`
- 关键输出文件：
  - `benchmark.csv`：原始逐次实验数据
  - `summary_by_condition.csv`：按 `chips+sparsity` 汇总
  - `summary_overall.csv`：按 `chips` 汇总

## 4. 推荐运行方式
- 快速自检（本地）：
```bash
conda run -n paper bash scripts/run_single_vs_multiprocess_fair.sh --quick
```

- 正式实验（建议）：
```bash
conda run -n paper bash scripts/run_single_vs_multiprocess_fair.sh \
  --chip-configs "4:16:16,16:8:8" \
  --sparsities "0.05,0.15,0.30" \
  --repeats 3 \
  --sim 12000 \
  --timesteps 5 \
  --interval 2000
```

## 5. 结果解释模板
- 以 `summary_by_condition.csv` 为准，关注：
  - `avg_single_sec`
  - `avg_multi_sec`
  - `speedup_single_over_multi`
- 论文可写法：
  - 若 `speedup_single_over_multi > 1`：多进程在该负载下获得加速。
  - 若 `< 1`：多进程开销（进程调度/文件I/O）超过收益。
- 必须分条件报告（不同 `chips/sparsity`），不要只报一个平均数。

## 6. 风险与注意
- 该实验证明的是“该机器+该参数下的端到端速度”，不是理论上恒快。
- 强烈建议在服务器复现实验（更多核心、更高并行度）后再下结论。
- 本地 quick 只用于通路验证，不用于论文主结论。

