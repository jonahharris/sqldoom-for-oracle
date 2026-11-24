#!/usr/bin/env python3
"""Download the data that is not kept in git, checksum-pinned.

    fetch_data.py wad          Freedoom 0.13.0 freedoom1.wad -> oracle/wad/ (the WAD all ground truth uses)
    fetch_data.py reference    the extended CedarDB ground truth (flows, scenarios, deathmatches, API
                               session; ~400 MB) -> oracle/reference_data/
    fetch_data.py shareware    the Doom 1.9 shareware doom1.wad (id Software; downloaded from Debian's
                               doom-wad-shareware package, never committed) -> oracle/wad/
    fetch_data.py sources      clone the three reference implementations into reference/ at the
                               commits this work was done against

`make test`, `make bench` and the game check need only `wad` (their ground truth, reference_data/e1m1
and e1m1_game, is in the repository). The flow, scenario, deathmatch and API-replay suites need
`reference`. The URL of the reference-data release asset is DOOM_REFERENCE_URL (default below).
"""
import hashlib, os, subprocess, sys, tarfile, tempfile, urllib.request, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ORA = ROOT / "oracle"

FREEDOOM_URL = "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
FREEDOOM_ZIP_SHA256 = "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
FREEDOOM1_WAD_SHA256 = "7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d"

SHAREWARE_DEB_URL = ("https://deb.debian.org/debian/pool/non-free/d/doom-wad-shareware/"
                     "doom-wad-shareware_1.9.fixed-5_all.deb")
SHAREWARE_DEB_SHA256 = "5802f176c0303e228095b5312def53de602781cf4c53e79842257484a0d9e938"
DOOM1_WAD_SHA256 = "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"  # v1.9 shareware

REFERENCE_URL = os.getenv("DOOM_REFERENCE_URL",
                          "https://github.com/jonahharris/sqldoom-for-oracle/releases/download/reference-data-v1/"
                          "sqldoom-oracle-reference-data.tar.gz")
REFERENCE_SHA256 = os.getenv("DOOM_REFERENCE_SHA256",
                             "0a632bd9444843c850fa6ee5f005eab69dd8fdc895d81d1438382776e4435685")

SOURCES = (  # (directory, repository, commit)
    ("sqldoom", "https://github.com/cedardb/sqldoom.git", "95753a2"),
    ("saildoom", "https://github.com/querygraph/saildoom.git", "200b57a"),
    ("DoomSQL", "https://github.com/sqlartist/DoomSQL.git", "41eff29"),
)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def download(url, dest, want):
    print(f"downloading {url}")
    urllib.request.urlretrieve(url, dest)
    got = sha256(dest)
    if want and not want.startswith("SET_") and got != want:
        sys.exit(f"checksum mismatch for {url}: {got} (expected {want})")
    return got


def fetch_wad():
    wad = ORA / "wad" / "freedoom1.wad"
    if wad.exists() and sha256(wad) == FREEDOOM1_WAD_SHA256:
        print(f"{wad.relative_to(ROOT)} already present")
        return
    with tempfile.TemporaryDirectory() as td:
        z = Path(td) / "freedoom.zip"
        download(FREEDOOM_URL, z, FREEDOOM_ZIP_SHA256)
        with zipfile.ZipFile(z) as zf:
            wad.write_bytes(zf.read("freedoom-0.13.0/freedoom1.wad"))
    if sha256(wad) != FREEDOOM1_WAD_SHA256:
        wad.unlink()
        sys.exit("freedoom1.wad checksum mismatch")
    print(f"wrote {wad.relative_to(ROOT)}")


def fetch_shareware():
    wad = ORA / "wad" / "doom1.wad"
    if wad.exists() and sha256(wad) == DOOM1_WAD_SHA256:
        print(f"{wad.relative_to(ROOT)} already present")
        return
    import io
    with tempfile.TemporaryDirectory() as td:
        deb = Path(td) / "shareware.deb"
        download(SHAREWARE_DEB_URL, deb, SHAREWARE_DEB_SHA256)
        raw = deb.read_bytes()
        if not raw.startswith(b"!<arch>\n"):
            sys.exit("not a .deb archive")
        pos, data = 8, None
        while pos < len(raw):  # ar members: 60-byte header, data padded to an even length
            name, size = raw[pos:pos + 16].decode().strip().rstrip("/"), int(raw[pos + 48:pos + 58])
            if name.startswith("data.tar"):
                data = raw[pos + 60:pos + 60 + size]
            pos += 60 + size + (size & 1)
        if data is None:
            sys.exit("no data.tar in the package")
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            wad.write_bytes(tf.extractfile("./usr/share/games/doom/doom1.wad").read())
    if sha256(wad) != DOOM1_WAD_SHA256:
        wad.unlink()
        sys.exit("doom1.wad checksum mismatch")
    print(f"wrote {wad.relative_to(ROOT)} (Doom 1.9 shareware, id Software; not redistributable)")


def fetch_reference():
    dest = ORA / "reference_data"
    with tempfile.TemporaryDirectory() as td:
        t = Path(td) / "ref.tar.gz"
        download(REFERENCE_URL, t, REFERENCE_SHA256)
        with tarfile.open(t, "r:gz") as tf:
            for m in tf.getmembers():  # the archive holds only reference_data/ subtrees
                if m.name.startswith(("/", "..")) or ".." in Path(m.name).parts or not (m.isfile() or m.isdir()):
                    sys.exit(f"unexpected archive member {m.name}")
            tf.extractall(dest)
    print(f"extracted into {dest.relative_to(ROOT)}")


def fetch_sources():
    ref = ROOT / "reference"
    ref.mkdir(exist_ok=True)
    for d, url, commit in SOURCES:
        p = ref / d
        if not p.exists():
            subprocess.run(["git", "clone", "-q", url, str(p)], check=True)
        subprocess.run(["git", "-C", str(p), "checkout", "-q", commit], check=True)
        print(f"reference/{d} at {commit}")


if __name__ == "__main__":
    what = sys.argv[1:] or ["wad"]
    for w in what:
        {"wad": fetch_wad, "shareware": fetch_shareware, "reference": fetch_reference, "sources": fetch_sources}[w]()
