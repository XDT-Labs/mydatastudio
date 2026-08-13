#!/usr/bin/env python3
"""Dump image embeddings + metadata from a My Data Studio database.

The Dart prototype harness reads two files rather than opening SQLite itself:
resqlite needs native assets that a plain `dart run` script cannot load, and a
flat binary is an order of magnitude faster to parse than hex-encoded BLOBs.

    vectors.f32   raw little-endian float32, row-major, n * dim values
    meta.tsv      one row per vector: file_id, collection, scanner, name, description

Usage:
    python3 dump_vectors.py <out_dir> [--type file|description] [--db PATH]
"""

import argparse
import os
import sqlite3
import sys

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/com.xdtlabs.mydatastudio.dev/data/mydata.db"
)

# Only rows whose vector is exactly this many bytes are dumped. A short or
# oversized BLOB means a partially written or wrong-model embedding; letting one
# through would silently shift every subsequent vector in the flat binary.
DIM = 2048
EXPECTED_BYTES = DIM * 4


def clean(value):
    """Flatten a text field to a single TSV-safe cell."""
    if not value:
        return ""
    return " ".join(str(value).split())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir")
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument(
        "--type",
        default="file",
        choices=["file", "description"],
        help="which embedding kind to dump ('file' = the image, "
        "'description' = its generated caption)",
    )
    args = parser.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f"database not found: {args.db}")
    os.makedirs(args.out_dir, exist_ok=True)

    # Read-only URI so a running app instance can't be disturbed by the dump.
    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rows = conn.execute(
        """
        SELECT e.file_id, c.name, c.scanner, f.name, f.description,
               e.qwen3_vl_embedding
        FROM files_embeddings e
        JOIN files f ON f.id = e.file_id
        JOIN collections c ON c.id = f.collection_id
        WHERE e.type = ?
          AND f.is_deleted = 0
          AND f.is_inline = 0
          AND e.qwen3_vl_embedding IS NOT NULL
        ORDER BY e.file_id
        """,
        (args.type,),
    )

    vec_path = os.path.join(args.out_dir, "vectors.f32")
    meta_path = os.path.join(args.out_dir, "meta.tsv")
    kept = 0
    skipped = 0

    with open(vec_path, "wb") as vec_f, open(meta_path, "w", encoding="utf-8") as meta_f:
        for file_id, collection, scanner, name, description, blob in rows:
            if blob is None or len(blob) != EXPECTED_BYTES:
                skipped += 1
                continue
            vec_f.write(blob)
            meta_f.write(
                "\t".join(
                    [
                        clean(file_id),
                        clean(collection),
                        clean(scanner),
                        clean(name),
                        clean(description),
                    ]
                )
                + "\n"
            )
            kept += 1

    conn.close()
    print(f"type={args.type} dim={DIM} vectors={kept} skipped={skipped}")
    print(f"  {vec_path}")
    print(f"  {meta_path}")
    if kept == 0:
        sys.exit("no vectors dumped — nothing to cluster")


if __name__ == "__main__":
    main()
