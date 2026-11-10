"""Minimal in-memory PostgREST + Storage fake for httpx.MockTransport."""
import json

import httpx


class FakeSupabase:
    def __init__(self):
        self.rows, self.objects, self.requests = {}, {}, []

    def _filter(self, params):
        rows = list(self.rows.values())
        for k, v in params.items():
            if k in ("select", "order", "limit"):
                continue
            op, val = v.split(".", 1)
            assert op == "eq"
            rows = [r for r in rows if str(r.get(k)).lower() == val.lower()]
        if "order" in params:
            for part in reversed(params["order"].split(",")):
                col, d = part.split(".")
                rows.sort(key=lambda r: r[col], reverse=d == "desc")
        if "limit" in params:
            rows = rows[: int(params["limit"])]
        return rows

    def __call__(self, req: httpx.Request) -> httpx.Response:
        self.requests.append(req)
        assert req.headers["apikey"] == "svc" and req.headers["authorization"] == "Bearer svc"
        p, params = req.url.path, dict(req.url.params)
        if p == "/rest/v1/styles":
            if req.method == "GET":
                return httpx.Response(200, json=self._filter(params))
            if req.method == "POST":
                row = json.loads(req.content)
                self.rows[row["id"]] = {**self.rows.get(row["id"], {}), **row}
                return httpx.Response(201)
            if req.method == "PATCH":
                for r in self._filter(params):
                    r.update(json.loads(req.content))
                return httpx.Response(204)
            if req.method == "DELETE":
                for r in self._filter(params):
                    self.rows.pop(r["id"])
                return httpx.Response(204)
        if p.startswith("/storage/v1/object/"):
            rest = p[len("/storage/v1/object/"):]
            if rest.startswith("authenticated/"):
                rest = rest[len("authenticated/"):]
            if req.method == "POST":
                self.objects[rest] = req.content
                return httpx.Response(200, json={"Key": rest})
            if req.method == "GET":
                return httpx.Response(200, content=self.objects[rest]) if rest in self.objects \
                    else httpx.Response(400, json={"error": "not_found"})
            if req.method == "DELETE":
                self.objects.pop(rest, None)
                return httpx.Response(200)
        return httpx.Response(404)
