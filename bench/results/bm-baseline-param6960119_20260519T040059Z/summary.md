# BM baseline: param6960119

Current base:
Accepted Syndrome packed_cwords optimization at ab513dfe317d931b50fc7eae3c75b4d1f6924e9c.

Purpose:
Collect Berlekamp-Massey baseline counters before optimization.

Rules:
- CPU not rerun
- CPU outputs not regenerated
- CUDA code not changed
- NCU used only for counters
- clean GPU-only timing captured before and after NCU

Inspect:
- profiles/Profile_GPU_optimised_6960119_before_ncu.txt
- profiles/Profile_GPU_optimised_6960119_after_ncu_clean.txt
- ncu/key_metrics.txt
- ncu/key_sections.txt
