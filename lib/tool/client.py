"""Thin requests.Session wrapper for Aleph's API. Handles ApiKey auth,
auto-appends /api/2 to bare hosts, repeats array params, and turns HTTP
error codes into CommandError with targeted suggestions."""

from __future__ import annotations

import re

import requests

from .errors import CommandError


class AlephClient:
    def __init__(self, base_url: str, api_key: str, server_name: str = "",
                 timeout: float = 30.0) -> None:
        url = base_url.rstrip("/")
        # Aleph's API lives under /api/2. Auto-append if the user gave a bare host.
        if not re.search(r"/api/v?\d+$", url):
            url = url + "/api/2"
        self.base_url = url
        self.api_key = api_key
        self.server_name = server_name or self._derive_server(self.base_url)
        self.timeout = timeout
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"ApiKey {api_key}",
            "Accept": "application/json",
        })

    @staticmethod
    def _derive_server(base_url: str) -> str:
        m = re.match(r"https?://([^/]+)", base_url)
        if not m:
            return ""
        host = m.group(1).lower()
        parts = host.split(".")
        generic = {"aleph", "search", "bar", "www"}
        if parts and parts[0] in generic and len(parts) > 1:
            return parts[1]
        return parts[0] if parts else ""

    def get(self, path: str, params: dict | None = None) -> dict:
        url = f"{self.base_url}{path}"
        # Build query items, repeating arrays.
        query_items: list[tuple[str, str]] = []
        if params:
            for k in sorted(params.keys()):
                v = params[k]
                if v is None:
                    continue
                if isinstance(v, list):
                    for item in v:
                        query_items.append((k, str(item)))
                elif isinstance(v, bool):
                    query_items.append((k, "true" if v else "false"))
                else:
                    query_items.append((k, str(v)))
        try:
            resp = self._session.get(url, params=query_items, timeout=self.timeout)
        except requests.RequestException as e:
            raise CommandError(
                f"network error: {e}",
                "check connectivity and ALEPH_URL",
            )
        if resp.status_code >= 400:
            raise self._parse_error(resp)
        try:
            return resp.json()
        except ValueError:
            ct = resp.headers.get("content-type", "")
            preview = (resp.text or "")[:120].replace("\n", " ")
            raise CommandError(
                f"non-JSON response from {path} (content-type={ct})",
                f"check ALEPH_URL points at the API root (e.g. https://aleph.example.org/api/2). "
                f"got: {preview!r}",
            )

    def _parse_error(self, resp: requests.Response) -> CommandError:
        msg = ""
        try:
            j = resp.json()
            if isinstance(j, dict) and isinstance(j.get("message"), str):
                msg = j["message"].split("\n", 1)[0]
        except Exception:
            msg = (resp.text or "")[:200]
        code = resp.status_code
        if code == 400 and "schema" in msg.lower():
            return CommandError(
                "server requires a schema filter for this query",
                "add type=emails|docs|web|people|orgs",
            )
        if code in (401, 403):
            return CommandError(
                f"auth failed (HTTP {code}): {msg}",
                "check your ALEPH_API_KEY",
            )
        if code == 404:
            return CommandError(f"not found: {msg}", "verify the entity ID or alias")
        if code == 429:
            return CommandError("rate-limited by server", "wait a few seconds and retry")
        return CommandError(f"HTTP {code}: {msg or 'request failed'}")
