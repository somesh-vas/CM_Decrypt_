# A/B syndrome-packed-cwords-param8192128

Change:
Only param8192128 SyndromeKernel changed from shared gf c[sb] unpacked-bit storage to shared uint32_t c_words[(sb+31)/32] packed-bit storage.

Method:
- Correctness validated with make gpuopt-output PARAM=8192128 KATNUM=50000 ARCH=sm_75 and make compare-opt PARAM=all
- Baseline trials run from origin/codex-bench-system in a detached worktree
- Experiment trials run from the current accepted branch with only param8192128 Decrypt.cu edited
- param8192128 does not emit built-in per-stage timing text, so kernel timings were collected non-invasively from nsys cuda_gpu_kern_sum reports
- NCU was used only for experiment-side counters, not for app timing

Rules:
- CPU not rerun
- CPU outputs not regenerated
- Chien unchanged
- BM unchanged
- param6960119 unchanged
- only param8192128 CUDA file edited
## baseline
- syndrome_ms: mean=19.036877, stdev=0.088200, min=18.879621, max=19.083271
- bm_ms: mean=29.312330, stdev=0.001134, min=29.311266, max=29.313763
- chien_ms: mean=160.195018, stdev=0.002781, min=160.192343, max=160.198680
- kernel_ms: mean=208.544224, stdev=0.086917, min=208.389568, max=208.591427
- kernel_ct_s: mean=239757.332508, stdev=99.980745, min=239703.043980, max=239935.235146

## experiment
- syndrome_ms: mean=17.350925, stdev=0.337578, min=16.932623, max=17.805304
- bm_ms: mean=29.312836, stdev=0.000620, min=29.311972, max=29.313603
- chien_ms: mean=160.196834, stdev=0.005371, min=160.192451, max=160.203703
- kernel_ms: mean=206.860595, stdev=0.342907, min=206.438040, max=207.322610
- kernel_ct_s: mean=241709.204868, stdev=400.574679, min=241170.029646, max=242203.423361
