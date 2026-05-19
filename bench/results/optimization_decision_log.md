# Optimization Decision Log

| Approach | Param(s) | Correctness | Result | Decision | Reason |
|---|---|---|---|---|---|
| Chien ballot packing | all tested params | Rejected during iteration | No accepted speedup | Reject | Did not produce an accepted benchmark win. |
| Chien mul32 integration | all tested params | Rejected during iteration | No accepted speedup | Reject | Increased complexity without making the final stack. |
| Chien unroll1 | all tested params | Rejected during iteration | No accepted speedup | Reject | Did not improve the final reportable outcome. |
| Chien launch_bounds(128,4) | all tested params | Rejected during iteration | No accepted speedup | Reject | Not part of the accepted optimization stack. |
| Chien global support load | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Chien tpb64 | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Chien 2-warps-per-ciphertext | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Chien shared sigma u32 | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Chien 4-warps-per-ciphertext | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Chien table4 multiply diagnostic | diagnostic only | Not a rollout candidate | Diagnostic only | Reject | Used only for diagnosis, not a production optimization. |
| Chien logexp multiply diagnostic | diagnostic only | Not a rollout candidate | Diagnostic only | Reject | Used only for diagnosis, not a production optimization. |
| Syndrome `uint32_t c[sb]` | all tested params | Rejected during iteration | No accepted speedup | Reject | Did not make the accepted stack. |
| Syndrome direct ciphertext bit loads | all tested params | Rejected during iteration | No accepted speedup | Reject | Rejected after evaluation. |
| Syndrome packed `c_words` | param348864 | Correct but not accepted | No final gain acceptance | Reject | Kept baseline implementation for this parameter. |
| Syndrome packed `c_words` | param460896 | Correct but not accepted | No final gain acceptance | Reject | Kept baseline implementation for this parameter. |
| Syndrome packed `c_words` | param6688128, param6960119, param8192128 | PASS | Included in accepted stack | Accept | Delivered the accepted Syndrome win for these larger params. |
| BM block64 | param6960119 | Correctness/benefit not accepted | Inferior to block128 | Reject | Block128 was the accepted BM choice. |
| BM block128 | param6960119 | PASS | Included in accepted stack | Accept | Accepted BM optimization for param6960119. |
| BM minimum-safe block size 128 -> 96 | param348864 | PASS | Included in accepted stack | Accept | Reduced BM time while preserving correctness. |
| BM minimum-safe block size 256 -> 160 | param6688128 | PASS | Included in accepted stack | Accept | Reduced BM time while preserving correctness. |
| BM minimum-safe block size 256 -> 160 | param8192128 | PASS | Included in accepted stack | Accept | Reduced BM time while preserving correctness. |
| BM block size unchanged at 128 | param460896 | PASS | Baseline retained | Accept | No safer/faster accepted alternative was rolled out. |
| BM block size unchanged at accepted 128 | param6960119 | PASS | Baseline accepted block retained | Accept | Existing accepted block128 remained the final choice. |
