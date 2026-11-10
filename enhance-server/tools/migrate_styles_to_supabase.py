#!/usr/bin/env python3
"""Copy local styles (SQLite rows + thumbnails + private refs) into Supabase.

  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python tools/migrate_styles_to_supabase.py \
      [--db styles.sqlite3] [--media media/styles] [--dry-run]

If the local DB doesn't exist, the bundled seed (seed_styles.json + seed_media)
is used. Idempotent: rows are upserted, files uploaded with x-upsert.
"""
import argparse
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

import styles as S  # noqa: E402
import supabase_styles as SB  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.join(HERE, "styles.sqlite3"))
    ap.add_argument("--media", default=os.path.join(HERE, "media", "styles"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if os.path.exists(a.db):
        local = S.StyleStore(a.db, a.media)
    else:
        tmp = tempfile.mkdtemp()
        local = S.StyleStore(os.path.join(tmp, "s.sqlite3"), os.path.join(tmp, "media"))
        local.seed_if_empty(os.path.join(HERE, "seed_styles.json"), os.path.join(HERE, "seed_media"))
        print("local DB not found → migrating bundled seed styles")
    rows = local.list(include_disabled=True)
    if a.dry_run:
        for s in rows:
            print(s.id, s.display_image, len(s.ref_images))
        return 0
    remote = SB.SupabaseStyleStore(os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    for s in rows:
        if s.display_image and (b := local.read_file(s.display_image)):
            remote.put_file(s.display_image, b)
        for f in s.ref_images:
            if b := local.read_file(f, private=True):
                remote.put_file(f, b, private=True)
        remote.upsert(s)
        print(f"migrated {s.id} (thumb={'yes' if s.display_image else 'no'}, refs={len(s.ref_images)})")
    print(f"done: {len(rows)} styles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
