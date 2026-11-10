#!/usr/bin/env python3
"""Add (or update) a photo style through the token-protected admin API.

Usage:
  ADMIN_API_TOKEN=... python tools/add_style.py style.json \
      [--server http://127.0.0.1:8000] [--thumbnail sample.jpg] \
      [--ref ref1.jpg --ref ref2.jpg] [--update] [--replace-refs]

style.json fields: name, category, prompt (required on create); optional id,
credit_cost, pro_only, enabled, sort_order, needs_person, free_trial,
thumbnail, refs (image paths, relative to the JSON file). CLI flags add to /
override the JSON paths. --update → PUT to an existing id (create otherwise;
an existing id without --update is an error).
Other commands:  --list   |   --delete ID
Only the standard library is used (urllib), so it runs anywhere.
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid


def call(server, token, method, path, body=None, content_type="application/json"):
    req = urllib.request.Request(server.rstrip("/") + path, data=body, method=method,
                                 headers={"Authorization": f"Bearer {token}"})
    if body is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"detail": str(e)}


def multipart(fields: dict, files: list) -> tuple[bytes, str]:
    b = uuid.uuid4().hex
    out = []
    for k, v in fields.items():
        out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    for k, path in files:
        ct = mimetypes.guess_type(path)[0] or "application/octet-stream"
        out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"; filename="{os.path.basename(path)}"\r\n'
                   f'Content-Type: {ct}\r\n\r\n'.encode() + open(path, "rb").read() + b"\r\n")
    out.append(f"--{b}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={b}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("json_file", nargs="?")
    ap.add_argument("--server", default=os.environ.get("STYLE_API_SERVER", "http://127.0.0.1:8000"))
    ap.add_argument("--token", default=os.environ.get("ADMIN_API_TOKEN", ""))
    ap.add_argument("--thumbnail")
    ap.add_argument("--ref", action="append", default=[])
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--replace-refs", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--delete")
    a = ap.parse_args(argv)
    if not a.token:
        print("error: set ADMIN_API_TOKEN or pass --token", file=sys.stderr)
        return 2
    if a.list:
        st, js = call(a.server, a.token, "GET", "/admin/api/styles")
        if st != 200:
            print(f"error {st}: {js}", file=sys.stderr); return 1
        for s in js["styles"]:
            print(f'{s["sort_order"]:>3}  {s["id"]:<28} {s["name"]:<24} {s["category"]:<10} '
                  f'{s["credit_cost"]}cr {"on " if s["enabled"] else "off"} refs={len(s["ref_images"])}')
        return 0
    if a.delete:
        st, js = call(a.server, a.token, "DELETE", f"/admin/api/styles/{a.delete}")
        print(json.dumps(js)); return 0 if st == 200 else 1
    if not a.json_file:
        ap.error("json_file required")
    data = json.load(open(a.json_file, encoding="utf-8"))
    base = os.path.dirname(os.path.abspath(a.json_file))
    rel = lambda p: p if os.path.isabs(p) else os.path.join(base, p)  # noqa: E731
    thumb = a.thumbnail or (rel(data["thumbnail"]) if data.get("thumbnail") else None)
    refs = [rel(p) for p in data.get("refs", [])] + a.ref
    for p in ([thumb] if thumb else []) + refs:
        if not os.path.isfile(p):
            print(f"error: image not found: {p}", file=sys.stderr); return 2
    fields = {k: v for k, v in data.items() if k not in ("thumbnail", "refs")}
    body = json.dumps(fields).encode()
    if a.update:
        if not data.get("id"):
            print("error: --update needs an id in the JSON", file=sys.stderr); return 2
        st, js = call(a.server, a.token, "PUT", f"/admin/api/styles/{data['id']}", body)
    else:
        st, js = call(a.server, a.token, "POST", "/admin/api/styles", body)
    if st not in (200, 201):
        print(f"error {st}: {js.get('detail', js)}", file=sys.stderr); return 1
    sid = js["id"]
    if thumb or refs or a.replace_refs:
        files = ([("display_image", thumb)] if thumb else []) + [("ref_images", p) for p in refs]
        mp, ct = multipart({"replace_refs": "1"} if a.replace_refs else {}, files)
        st, js = call(a.server, a.token, "POST", f"/admin/api/styles/{sid}/images", mp, ct)
        if st != 200:
            print(f"style {sid} saved but image upload failed {st}: {js.get('detail', js)}", file=sys.stderr)
            return 1
    print(json.dumps({"ok": True, "id": sid, "name": js["name"], "credit_cost": js["credit_cost"],
                      "display_image": js["display_image"], "ref_images": len(js["ref_images"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
