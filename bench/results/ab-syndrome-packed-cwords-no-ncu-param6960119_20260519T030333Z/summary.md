# A/B no-NCU timing: packed c_words Syndrome vs baseline

Purpose:
Validate real GPU-only timing because prior 9849 ms Syndrome time may have come from an NCU-instrumented executable run.

No CPU rerun.
No CPU output regeneration.
No NCU in this validation.
ARCH=sm_75
KATNUM=50000

## baseline
- throughput_ct_s: mean=70855.842000, stdev=1448.132505, min=69135.080000, max=72327.990000
- kernel_ct_s: mean=281977.763965, stdev=173.451587, min=281807.626842, max=282254.650145
- wall_ms: mean=705.894800, stdev=14.485895, min=691.295000, max=723.222000
- kernel_ms: mean=177.319000, stdev=0.109025, min=177.145000, max=177.426000
- syndrome_ms: mean=19.582400, stdev=0.106211, min=19.405000, max=19.677000
- bm_ms: mean=30.788800, stdev=0.005450, min=30.783000, max=30.796000
- chien_ms: mean=126.947800, stdev=0.008289, min=126.934000, max=126.955000

## packed_cwords
- throughput_ct_s: mean=69993.752000, stdev=3008.433139, min=66198.400000, max=72936.720000
- kernel_ct_s: mean=284428.945059, stdev=1511.416963, min=282719.079014, max=286355.722533
- wall_ms: mean=715.418600, stdev=31.102455, min=685.526000, max=755.305000
- kernel_ms: mean=175.794800, stdev=0.934155, min=174.608000, max=176.854000
- syndrome_ms: mean=18.053800, stdev=0.933702, min=16.887000, max=19.123000
- bm_ms: mean=30.792400, stdev=0.012300, min=30.780000, max=30.813000
- chien_ms: mean=126.948600, stdev=0.007092, min=126.941000, max=126.959000
