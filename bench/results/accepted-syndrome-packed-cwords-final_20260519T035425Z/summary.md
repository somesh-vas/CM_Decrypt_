# Accepted optimization: packed shared ciphertext words for large Syndrome kernels

Accepted commit:
f652ddcfe9a1fd679251ff4a9cf8aa7480df0ef8

## Final kept state

- param348864: reverted to baseline
- param460896: reverted to baseline
- param6688128: packed c_words accepted
- param6960119: packed c_words accepted
- param8192128: packed c_words accepted

## Results

| Param | Decision | Baseline Syndrome ms | Experiment Syndrome ms | Delta |
|---|---:|---:|---:|---:|
| 348864 | Reject/reverted | 3.140604 | 3.306519 | +5.28% slower |
| 460896 | Reject/reverted | 8.472467 | 9.188238 | +8.45% slower |
| 6688128 | Accept | 19.013594 | 17.335121 | -8.83% faster |
| 6960119 | Accept | 19.582400 | 17.363946 | -11.33% faster |
| 8192128 | Accept | 19.036877 | 17.423423 | -8.48% faster |

## Conclusion

Packed shared c_words reduces SyndromeKernel shared-memory bank conflict cost for the large parameter sets, but the packing/extraction overhead outweighs the benefit for smaller parameter sets.

Keep packed c_words only for:
6688128, 6960119, 8192128.

Keep original shared gf c[sb] for:
348864, 460896.
