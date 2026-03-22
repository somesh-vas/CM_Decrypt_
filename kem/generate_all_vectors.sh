#!/bin/sh
# Build and run every enabled KEM variant so all projects share one vector set.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="$ROOT/test_vectors/Cipher_Sk"
mkdir -p "$OUT_DIR"

# Keep this list aligned with the top-level workspace parameter support.
VARIANTS="variant_348864 variant_460896 variant_6688128 variant_6960119 variant_8192128"

for variant in $VARIANTS; do
    echo "[+] Building and running $variant"
    (
        cd "$ROOT/$variant"
        if [ -x ./build ]; then
            ./build
        else
            sh ./build
        fi

        if [ -x ./run ]; then
            ./run
        else
            sh ./run
        fi
    )
done

echo "[+] Done. Test vectors are in: $OUT_DIR"
