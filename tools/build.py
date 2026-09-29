#!/usr/bin/env python3
"""Собирает install.ps1: вшивает server/setup.sh и server/vpn (base64 + SHA-256).
Запуск из корня репозитория: python3 tools/build.py"""
import base64, hashlib, pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
def blob(name):
    data = (root / "server" / name).read_bytes().replace(b"\r\n", b"\n")
    return base64.b64encode(data).decode(), hashlib.sha256(data).hexdigest()
setup_b64, setup_sha = blob("setup.sh")
vpn_b64, vpn_sha = blob("vpn")
t = (root / "tools" / "install.ps1.in").read_text(encoding="utf-8")
t = (t.replace("@SETUP_B64@", setup_b64).replace("@VPN_B64@", vpn_b64)
      .replace("@SETUP_SHA@", setup_sha).replace("@VPN_SHA@", vpn_sha).replace("@VERSION@", version))
assert not re.search(r"@[A-Z_]+@", t), "остались незаполненные метки"
t = t.replace("\r\n", "\n").replace("\n", "\r\n")          # Windows: CRLF
(root / "install.ps1").write_bytes(b"\xef\xbb\xbf" + t.encode("utf-8"))  # UTF-8 с BOM — иначе PowerShell 5.1 ломает кириллицу
print(f"install.ps1 собран: v{version}, setup.sh {setup_sha[:12]}…, vpn {vpn_sha[:12]}…")
