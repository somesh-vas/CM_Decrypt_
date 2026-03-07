#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="$ROOT/test_vectors/Cipher_Sk"
mkdir -p "$OUT_DIR"

VARIANTS="variant_348864 variant_460896c variant_6688128c variant_8192128c"

for variant in $VARIANTS; do
    echo "[+] Building and running $variant"
    (
        cd "$ROOT/$variant"
        ./build
        ./run
    )
done

echo "[+] Done. Test vectors are in: $OUT_DIR"
