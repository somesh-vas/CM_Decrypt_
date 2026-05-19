# Batch packed c_words rollout

Final kept state:
- `param348864`: reverted to baseline after regression
- `param460896`: reverted to baseline after regression
- `param6688128`: kept packed `c_words`
- `param6960119`: already had accepted packed `c_words`
- `param8192128`: already had accepted packed `c_words`

## param348864
- experiment syndrome_ms mean=3.306519, stdev=0.008453
- experiment kernel_ct_s mean=1346205.335913, stdev=302.464141
- baseline syndrome_ms=3.140604 (origin/codex-bench-system nsys baseline)
- baseline kernel_ct_s=1352235.732591 (origin/codex-bench-system nsys baseline)
- syndrome delta_ms=0.165915, delta_pct=5.28%
- kernel throughput delta_ct_s=-6030.396678
- ncu shared_store_bank_conflicts=28566
- ncu no_eligible=27.91
- ncu long_scoreboard_cycles=n/a
- regressed=True

## param460896
- experiment syndrome_ms mean=9.188238, stdev=0.081925
- experiment kernel_ct_s mean=482277.709113, stdev=383.242057
- baseline syndrome_ms=8.472467 (origin/codex-bench-system nsys baseline)
- baseline kernel_ct_s=485628.308162 (origin/codex-bench-system nsys baseline)
- syndrome delta_ms=0.715771, delta_pct=8.45%
- kernel throughput delta_ct_s=-3350.599049
- ncu shared_store_bank_conflicts=58553
- ncu no_eligible=38.59
- ncu long_scoreboard_cycles=8.5
- regressed=True

## param6688128
- experiment syndrome_ms mean=17.335121, stdev=0.568537
- experiment kernel_ct_s mean=281780.026213, stdev=904.138474
- baseline syndrome_ms=19.013594 (origin/codex-bench-system nsys baseline)
- baseline kernel_ct_s=279136.823072 (origin/codex-bench-system nsys baseline)
- syndrome delta_ms=-1.678474, delta_pct=-8.83%
- kernel throughput delta_ct_s=2643.203140
- ncu shared_store_bank_conflicts=79840
- ncu no_eligible=45.41
- ncu long_scoreboard_cycles=17.0
- regressed=False

## param6960119
- experiment syndrome_ms mean=17.363946, stdev=0.601106
- experiment kernel_ct_s mean=285724.200368, stdev=982.267848
- baseline syndrome_ms=19.582400 (prior accepted no-NCU baseline)
- baseline kernel_ct_s=281977.763965 (prior accepted no-NCU baseline)
- syndrome delta_ms=-2.218454, delta_pct=-11.33%
- kernel throughput delta_ct_s=3746.436403
- ncu shared_store_bank_conflicts=71807
- ncu no_eligible=41.76
- ncu long_scoreboard_cycles=13.1
- regressed=False

## param8192128
- experiment syndrome_ms mean=17.423423, stdev=0.926486
- experiment kernel_ct_s mean=241631.005619, stdev=1078.185793
- baseline syndrome_ms=19.036877 (prior baseline nsys A/B run)
- baseline kernel_ct_s=239757.332508 (prior baseline nsys A/B run)
- syndrome delta_ms=-1.613454, delta_pct=-8.48%
- kernel throughput delta_ct_s=1873.673111
- ncu shared_store_bank_conflicts=79633
- ncu no_eligible=44.76
- ncu long_scoreboard_cycles=15.9
- regressed=False
