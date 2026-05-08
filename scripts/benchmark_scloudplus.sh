#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/bench_results/$(date +%Y%m%d_%H%M%S)}"
CC_BIN="${CC:-gcc}"
BENCH_SECONDS="${BENCH_SECONDS:-1}"
TEST_ITERATIONS="${TEST_ITERATIONS:-100}"
RUNS="${RUNS:-1}"
KEEP_BINARIES="${KEEP_BINARIES:-0}"

COMMON_DEFS="-DKEM_BENCH_SECONDS=${BENCH_SECONDS} -DKEM_TEST_ITERATIONS=${TEST_ITERATIONS}"
REF_CFLAGS="${REF_CFLAGS:--O3 -g}"
OPT_CFLAGS="${OPT_CFLAGS:--O3 -march=native -g}"

if [[ "$(uname -m)" =~ ^(x86_64|amd64|i[3-6]86)$ ]]; then
  # This codebase uses aes_ni.c, so a non-native reference-style build still
  # needs AES-NI enabled on x86/x86_64 hosts.
  REF_CFLAGS="${REF_CFLAGS} -maes"
fi

mkdir -p "$OUT_DIR"

log() { printf '[scloudplus-bench] %s\n' "$*"; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--help]

One-command benchmark runner for Scloud+.

Environment variables:
  CC=gcc|clang             Compiler to use. Default: gcc
  BENCH_SECONDS=SECONDS    Seconds per benchmark operation in test.c. Default: 1
  TEST_ITERATIONS=N        Correctness-test iterations. Default: 100
  RUNS=N                   Repeat each executable N times. Default: 1
  OUT_DIR=PATH             Output directory. Default: bench_results/<timestamp>
  REF_CFLAGS='...'         Flags for ref/reference-style build. Default: -O3 -g
  OPT_CFLAGS='...'         Flags for optimized build. Default: -O3 -march=native -g
  KEEP_BINARIES=1          Keep built binaries in each source directory.

Examples:
  ./scripts/benchmark_scloudplus.sh
  BENCH_SECONDS=3 RUNS=5 ./scripts/benchmark_scloudplus.sh
  CC=clang OPT_CFLAGS='-O3 -march=native -flto -g' ./scripts/benchmark_scloudplus.sh

Directory layout:
  If ./ref and/or ./optimized directories exist, this script benchmarks them.
  Otherwise it benchmarks ./src twice: once with ref flags and once with
  optimized flags, so the difference is compiler tuning rather than source code.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

find_source_dir() {
  local base="$1"
  if [[ -f "$base/Makefile" && -f "$base/test.c" ]]; then
    printf '%s\n' "$base"
  elif [[ -f "$base/src/Makefile" && -f "$base/src/test.c" ]]; then
    printf '%s\n' "$base/src"
  else
    return 1
  fi
}

declare -a VARIANT_NAMES=()
declare -a VARIANT_DIRS=()
declare -a VARIANT_FLAGS=()

if ref_dir="$(find_source_dir "$ROOT_DIR/ref" 2>/dev/null)"; then
  VARIANT_NAMES+=("ref")
  VARIANT_DIRS+=("$ref_dir")
  VARIANT_FLAGS+=("$REF_CFLAGS $COMMON_DEFS")
fi
if opt_dir="$(find_source_dir "$ROOT_DIR/optimized" 2>/dev/null)"; then
  VARIANT_NAMES+=("optimized")
  VARIANT_DIRS+=("$opt_dir")
  VARIANT_FLAGS+=("$OPT_CFLAGS $COMMON_DEFS")
fi
if [[ ${#VARIANT_NAMES[@]} -eq 0 ]]; then
  src_dir="$(find_source_dir "$ROOT_DIR/src")"
  VARIANT_NAMES+=("ref")
  VARIANT_DIRS+=("$src_dir")
  VARIANT_FLAGS+=("$REF_CFLAGS $COMMON_DEFS")
  VARIANT_NAMES+=("optimized")
  VARIANT_DIRS+=("$src_dir")
  VARIANT_FLAGS+=("$OPT_CFLAGS $COMMON_DEFS")
fi

{
  echo "# Scloud+ benchmark report"
  echo
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Host: $(uname -a)"
  echo "Compiler: $($CC_BIN --version | head -n 1)"
  echo "BENCH_SECONDS: $BENCH_SECONDS"
  echo "TEST_ITERATIONS: $TEST_ITERATIONS"
  echo "RUNS: $RUNS"
  echo
  echo "## CPU flags relevant to acceleration"
  if command -v lscpu >/dev/null 2>&1; then
    lscpu | awk -F: '/Model name|Flags/ {gsub(/^[ \t]+/, "", $2); print "- " $1 ": " $2}'
  elif [[ -r /proc/cpuinfo ]]; then
    awk -F: '/model name|flags/ {gsub(/^[ \t]+/, "", $2); print "- " $1 ": " $2; exit}' /proc/cpuinfo
  else
    echo "- CPU flag detection unavailable on this platform."
  fi
  echo
  echo "## Source SIMD scan"
  if rg -n "_mm256|__m256|immintrin\.h|AVX2|avx2" "$ROOT_DIR/src" >/tmp/scloudplus_avx2_scan.$$ 2>/dev/null; then
    echo "- AVX2-looking source references found: yes"
    sed 's/^/  - /' /tmp/scloudplus_avx2_scan.$$
  else
    echo "- AVX2-looking source references found: no"
  fi
  rm -f /tmp/scloudplus_avx2_scan.$$
  if rg -n "wmmintrin\.h|_mm_aes|AES-NI|aes_ni" "$ROOT_DIR/src" >/tmp/scloudplus_aes_scan.$$ 2>/dev/null; then
    echo "- AES-NI-looking source references found: yes"
    sed 's/^/  - /' /tmp/scloudplus_aes_scan.$$
  else
    echo "- AES-NI-looking source references found: no"
  fi
  rm -f /tmp/scloudplus_aes_scan.$$
  echo
} > "$OUT_DIR/report.md"

printf 'variant,parameter,run,operation,iterations,total_time_s,mean_time_us,stdev_time_us,mean_cycles,stdev_cycles\n' > "$OUT_DIR/results.csv"

parse_output() {
  local variant="$1" run_id="$2" file="$3"
  awk -v variant="$variant" -v run="$run_id" '
    /Testing correctness/ {
      parameter=$0
      sub(/^.*system /, "", parameter)
      sub(/,tests.*$/, "", parameter)
    }
    /^(Key generation|KEM encapsulate|KEM decapsulate|KEM enc and decapsulate)/ {
      stdev_cycles=$NF; mean_cycles=$(NF-1); stdev_time=$(NF-2); mean_time=$(NF-3); total_time=$(NF-4); iterations=$(NF-5)
      operation=$0
      sub(/[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+$/, "", operation)
      gsub(/,/, " ", operation); gsub(/,/, " ", parameter)
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", variant, parameter, run, operation, iterations, total_time, mean_time, stdev_time, mean_cycles, stdev_cycles
    }
  ' "$file" >> "$OUT_DIR/results.csv"
}

scan_binary_avx2() {
  local bin="$1"
  if ! command -v objdump >/dev/null 2>&1; then
    echo "objdump unavailable"
    return 0
  fi
  if objdump -d "$bin" | rg -i '\b(vpadd|vpsub|vpmul|vperm|vpbroadcast|vpgather|vpsll|vpsrl|vpsra|vextracti128|vinserti128|ymm[0-9]+)\b' >/dev/null; then
    echo "yes"
  else
    echo "no"
  fi
}

for i in "${!VARIANT_NAMES[@]}"; do
  variant="${VARIANT_NAMES[$i]}"
  src="${VARIANT_DIRS[$i]}"
  flags="${VARIANT_FLAGS[$i]}"
  build_log="$OUT_DIR/${variant}_build.log"
  log "Building $variant in $src with CFLAGS='$flags'"
  make -C "$src" clean >"$build_log" 2>&1
  make -C "$src" CC="$CC_BIN" CFLAGS="$flags" all >>"$build_log" 2>&1

  mapfile -t bins < <(find "$src" -maxdepth 1 -type f -perm -111 -name 'scloudplus*_aes*' | sort)
  if [[ ${#bins[@]} -eq 0 ]]; then
    log "No benchmark binaries found for $variant"
    exit 1
  fi

  {
    echo "## Variant: $variant"
    echo
    echo "Source directory: $src"
    echo "CFLAGS: $flags"
    echo "Build log: $(basename "$build_log")"
    echo
    echo "### Compiler feature macros"
    if echo | "$CC_BIN" $flags -dM -E - 2>/dev/null | rg '__AVX2__|__AVX__|__AES__|__SSE2__'; then :; else
      echo "No matching AVX/AES/SSE2 feature macros emitted for these flags."
    fi
    echo
    echo "### Binary AVX2 disassembly scan"
  } >> "$OUT_DIR/report.md"

  for bin in "${bins[@]}"; do
    bin_name="$(basename "$bin")"
    avx2_result="$(scan_binary_avx2 "$bin")"
    echo "- $bin_name: AVX2-looking instructions: $avx2_result" >> "$OUT_DIR/report.md"
    for run in $(seq 1 "$RUNS"); do
      out_file="$OUT_DIR/${variant}_${bin_name}_run${run}.txt"
      log "Running $variant/$bin_name run $run"
      "$bin" > "$out_file"
      parse_output "$variant" "$run" "$out_file"
    done
  done
  echo >> "$OUT_DIR/report.md"

  if [[ "$KEEP_BINARIES" != "1" ]]; then
    make -C "$src" clean >>"$build_log" 2>&1 || true
  fi
done

log "Done. Results:"
log "  $OUT_DIR/report.md"
log "  $OUT_DIR/results.csv"
