# Final Accepted Optimizations Benchmark

- Baseline: `origin/codex-bench-system`
- Accepted optimized base: `66c80273eb33109b0b082752f7106e12494cc6d1`
- Instrumented optimized commit: `17eba578f971523e318208c8de1066015c70c00b`
- ARCH: `sm_75`
- KATNUM: `50000`
- Trials per param per variant: `5`

## Mean Throughput

| Param | Baseline total ct/s | Optimized total ct/s | Delta ct/s | Improvement | Baseline kernel ct/s | Optimized kernel ct/s | Delta kernel ct/s | Kernel improvement |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 348864 | 148733.05 | 149822.02 | 1088.97 | 0.73% | 1316302.15 | 1352031.26 | 35729.10 | 2.71% |
| 460896 | 128723.94 | 126902.25 | -1821.69 | -1.42% | 474315.82 | 474275.31 | -40.51 | -0.01% |
| 6688128 | 69130.49 | 69639.43 | 508.94 | 0.74% | 270161.62 | 281232.06 | 11070.43 | 4.10% |
| 6960119 | 71607.12 | 73185.10 | 1577.98 | 2.20% | 281893.76 | 300974.48 | 19080.72 | 6.77% |
| 8192128 | 59059.22 | 58623.19 | -436.02 | -0.74% | 232100.69 | 240405.35 | 8304.65 | 3.58% |

## Mean Timing Breakdown

| Param | Baseline Syndrome ms | Optimized Syndrome ms | Baseline BM ms | Optimized BM ms | Baseline Chien ms | Optimized Chien ms | Baseline kernel ms | Optimized kernel ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 348864 | 3.212 | 3.207 | 8.518 | 7.522 | 26.255 | 26.252 | 37.985 | 36.981 |
| 460896 | 8.835 | 8.846 | 15.682 | 15.685 | 80.898 | 80.893 | 105.415 | 105.424 |
| 6688128 | 19.172 | 18.925 | 35.154 | 28.069 | 130.749 | 130.795 | 185.074 | 177.789 |
| 6960119 | 19.647 | 17.771 | 30.779 | 21.421 | 126.945 | 126.937 | 177.372 | 166.128 |
| 8192128 | 19.195 | 18.983 | 36.064 | 28.891 | 160.165 | 160.109 | 215.424 | 207.982 |

## Overall Improvement Summary

- Mean total-throughput improvement across params: 0.30%
- Mean kernel-throughput improvement across params: 3.43%
- Best total-throughput gain: 2.20%
- Best kernel-throughput gain: 6.77%

## Notes

- Correctness validation used existing CPU errorstreams via `make compare-opt PARAM=all`.
- Timing is from GPU-only `Profile_GPU_optimised_<param>.txt` outputs with no NCU timing.
