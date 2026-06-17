#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare split errorstream chunks.")
    ap.add_argument("--param", required=True)
    ap.add_argument("--ref-dir", required=True, type=Path)
    ap.add_argument("--test-dir", required=True, type=Path)
    ap.add_argument("--chunk-size", required=True, type=int)
    ap.add_argument("--katnum", required=True, type=int)
    ap.add_argument("--sample-count", type=int, default=1)
    ap.add_argument("--mode", choices=["full", "first-last"], default="full")
    ap.add_argument("--json-out", type=Path)
    args = ap.parse_args()

    expected = (args.katnum + args.chunk_size - 1) // args.chunk_size
    indices = list(range(expected))
    if args.mode == "first-last":
        n = max(1, args.sample_count)
        indices = sorted(set(indices[:n] + indices[-n:]))

    rows = []
    status = "PASS"
    first_mismatch = None
    for idx in indices:
        name = f"errorstream0_{args.param}_chunk{idx:03d}.bin"
        ref = args.ref_dir / name
        test = args.test_dir / name
        row = {"chunk": idx, "ref": str(ref), "test": str(test)}
        if not ref.exists() or not test.exists():
            row["status"] = "MISSING"
            status = "FAIL"
            first_mismatch = first_mismatch or row
        else:
            ref_hash = sha256(ref)
            test_hash = sha256(test)
            row.update({
                "ref_bytes": ref.stat().st_size,
                "test_bytes": test.stat().st_size,
                "ref_sha256": ref_hash,
                "test_sha256": test_hash,
                "status": "PASS" if ref_hash == test_hash else "FAIL",
            })
            if row["status"] != "PASS":
                status = "FAIL"
                first_mismatch = first_mismatch or row
        rows.append(row)

    result = {
        "param": args.param,
        "katnum": args.katnum,
        "chunk_size": args.chunk_size,
        "expected_chunks": expected,
        "checked_chunks": len(indices),
        "mode": args.mode,
        "overall_status": status,
        "first_mismatch": first_mismatch,
        "chunks": rows,
    }
    text = json.dumps(result, indent=2)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(text + "\n")
    print(text)
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
