# scloudplus

Scloud+: An Efficient LWE-based KEM Without Ring/Module Structure

## Performance testing

Use the helper script to build and benchmark both a reference-style profile and an optimized profile:

```sh
./scripts/benchmark_scloudplus.sh
```

The script writes a timestamped directory under `bench_results/` containing:

- `report.md`: host/compiler information, CPU acceleration flags, source-level SIMD scan, build flags, and binary disassembly scan for AVX2-looking instructions.
- `results.csv`: parsed benchmark rows for Scloud+ 128/192/256 key generation, encapsulation, decapsulation, and encapsulation+decapsulation.
- raw program output and build logs for each variant.

Useful knobs:

```sh
BENCH_SECONDS=3 RUNS=5 ./scripts/benchmark_scloudplus.sh
CC=clang OPT_CFLAGS='-O3 -march=native -flto -g' ./scripts/benchmark_scloudplus.sh
KEEP_BINARIES=1 ./scripts/benchmark_scloudplus.sh
```

If this checkout contains separate `ref/` and/or `optimized/` source directories, the script benchmarks those directories. In the current single-`src/` layout, it benchmarks `src/` twice:

- `ref`: `-O3 -g` plus `-maes` on x86/x86_64 because this codebase uses `aes_ni.c`.
- `optimized`: `-O3 -march=native -g`.

## AVX2 status

The current implementation does not contain explicit AVX2 intrinsics such as `_mm256_*`, `__m256`, or `immintrin.h`. It does contain an AES-NI implementation in `src/aes_ni.c` using `<wmmintrin.h>` and `_mm_aes*` intrinsics. Therefore, the optimized build is best described as AES-NI accelerated; it is not explicitly AVX2-optimized unless the compiler auto-vectorizes some loops into AVX2 when `-march=native` enables AVX2 on the host. The benchmark script checks both compiler feature macros and the final binaries with `objdump` to help verify whether AVX2 instructions actually appear.
