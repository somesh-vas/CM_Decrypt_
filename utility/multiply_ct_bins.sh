#!/bin/sh
set -eu

usage() {
    echo "Usage: $0 <multiplier_n> [cipher_sk_dir]" >&2
    echo "Example: $0 3 kem/test_vectors/Cipher_Sk" >&2
}

ct_bytes_for() {
    case "$1" in
        ct_348864.bin) echo 96 ;;
        ct_460896.bin) echo 156 ;;
        ct_6688128.bin) echo 208 ;;
        ct_8192128.bin) echo 208 ;;
        *) echo 0 ;;
    esac
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 1
fi

MULT="$1"
DIR="${2:-kem/test_vectors/Cipher_Sk}"

case "$MULT" in
    ''|*[!0-9]*)
        echo "Error: multiplier_n must be a positive integer." >&2
        exit 1
        ;;
esac

if [ "$MULT" -le 0 ]; then
    echo "Error: multiplier_n must be >= 1." >&2
    exit 1
fi

if [ ! -d "$DIR" ]; then
    echo "Error: directory not found: $DIR" >&2
    exit 1
fi

set -- "$DIR"/ct_*.bin
if [ "$1" = "$DIR/ct_*.bin" ]; then
    echo "Error: no ct_*.bin files found in $DIR" >&2
    exit 1
fi

if [ "$MULT" -eq 1 ]; then
    echo "Multiplier is 1; no changes made."
    exit 0
fi

echo "Multiplying ciphertext vectors in $DIR by n=$MULT"

for file in "$DIR"/ct_*.bin; do
    [ -f "$file" ] || continue

    base="$(basename "$file")"
    before_bytes="$(wc -c < "$file" | tr -d '[:space:]')"
    tmp_file="$(mktemp "$DIR/.${base}.tmp.XXXXXX")"

    i=0
    while [ "$i" -lt "$MULT" ]; do
        cat "$file" >> "$tmp_file"
        i=$((i + 1))
    done

    mv "$tmp_file" "$file"
    after_bytes="$(wc -c < "$file" | tr -d '[:space:]')"

    ct_bytes="$(ct_bytes_for "$base")"
    if [ "$ct_bytes" -gt 0 ] && [ $((before_bytes % ct_bytes)) -eq 0 ] && [ $((after_bytes % ct_bytes)) -eq 0 ]; then
        before_ct="$((before_bytes / ct_bytes))"
        after_ct="$((after_bytes / ct_bytes))"
        echo "$base: ${before_ct} -> ${after_ct} ciphertexts (${before_bytes} -> ${after_bytes} bytes)"
    else
        echo "$base: ${before_bytes} -> ${after_bytes} bytes"
    fi
done

echo "Done."
