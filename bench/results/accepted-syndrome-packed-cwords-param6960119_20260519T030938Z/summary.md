# Accepted optimization: syndrome-packed-cwords-param6960119

Change:
param6960119 SyndromeKernel now stores ciphertext bits as packed shared uint32_t c_words[(sb+31)/32] instead of unpacked gf c[sb].

Validated by prior A/B no-NCU test:
- baseline Syndrome mean: 19.582400 ms
- packed_cwords Syndrome mean: 18.053800 ms
- improvement: 1.528600 ms, ~7.81%
- baseline kernel throughput: 281977.763965 ct/s
- packed_cwords kernel throughput: 284428.945059 ct/s

Important:
NCU app timing is ignored because NCU instrumentation polluted timing in earlier runs. NCU is used only for counters.

Rules:
- CPU not rerun
- CPU outputs not regenerated
- Chien unchanged
- BM unchanged
- only param6960119 CUDA file edited
