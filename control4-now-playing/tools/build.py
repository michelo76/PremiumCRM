#!/usr/bin/env python3
"""
Package the Now Playing Info Control4 driver (python3 stdlib only).

    python3 tools/build.py              # validate + build build/now_playing_info.c4z
    python3 tools/build.py --check      # validate only
    python3 tools/build.py --out DIR    # write the c4z somewhere else
    python3 tools/build.py --smoke DIR  # also unzip into DIR and run tests/c4/c4z_smoke.lua
                                        # (driver.lua loaded FROM THE UNZIPPED TREE) with lua5.1/luajit

What it does
  * driver/driver.xml must be well-formed; <script>/<documentation>/icon files it references
    (controller://driver/now_playing_info/..., image_source="c4z" paths) must exist in driver/www.
  * driver/www/index.html (the web UI) must exist.
  * every require("a.b") in the packaged Lua must resolve to a packaged a/b.lua (or be a known
    platform module).
  * stamps, IN THE PACKAGED COPY ONLY: driver.xml <version> (from driver/c4/version.lua:
    major*10000 + minor*100 + patch) and <modified> (MM/DD/YYYY HH:MM), and c4/version.lua
    BUILD_DATE. Set SOURCE_DATE_EPOCH for reproducible output.
  * zips driver/ (driver.xml and driver.lua first, then sorted paths; junk excluded; fixed
    timestamps) into build/now_playing_info.c4z and prints a manifest.
  * (re)writes driver/now_playing_info.c4zproj, a DriverPackager-compatible manifest.
The c4z name matters: controller://driver/<c4z name>/ maps to the c4z www/ folder.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = os.path.join(ROOT, "driver")
NAME = "now_playing_info"

JUNK_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini"}
JUNK_DIRS = {"__pycache__", ".git", ".svn", "node_modules"}
JUNK_EXT = (".swp", ".swo", ".tmp", ".bak", ".orig", ".c4z", ".c4zproj", "~")
PLATFORM_MODULES = set()  # DriverWorks built-ins we may require one day (none today)


class BuildError(Exception):
    pass


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def version_info():
    src = read(os.path.join(DRIVER, "c4", "version.lua"))
    m = re.search(r'M\.VERSION\s*=\s*"(\d+)\.(\d+)\.(\d+)"', src)
    if not m:
        raise BuildError("c4/version.lua: VERSION not found")
    major, minor, patch = (int(x) for x in m.groups())
    fname = re.search(r'M\.DRIVER_FILENAME\s*=\s*"([^"]+)"', src)
    if not fname or fname.group(1) != NAME:
        raise BuildError("c4/version.lua DRIVER_FILENAME must be %r" % NAME)
    return "%d.%d.%d" % (major, minor, patch), major * 10000 + minor * 100 + patch


def collect_files():
    files = []
    for dirpath, dirnames, filenames in os.walk(DRIVER):
        dirnames[:] = sorted(d for d in dirnames if d not in JUNK_DIRS and not d.startswith("."))
        for fn in filenames:
            if fn in JUNK_NAMES or fn.startswith(".") or fn.endswith(JUNK_EXT):
                continue
            full = os.path.join(dirpath, fn)
            files.append(os.path.relpath(full, DRIVER).replace(os.sep, "/"))
    first = ["driver.xml", "driver.lua"]
    rest = sorted(f for f in files if f not in first)
    for f in first:
        if f not in files:
            raise BuildError("missing driver/" + f)
    return first + rest


def validate_xml(files):
    raw = read(os.path.join(DRIVER, "driver.xml"), "rb")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        raise BuildError("driver.xml is not well-formed: %s" % e)
    if root.tag != "devicedata":
        raise BuildError("driver.xml root must be <devicedata>")
    problems = []
    fileset = set(files)
    script = root.find("./config/script")
    if script is None or script.get("file") != "driver.lua":
        problems.append('<config><script file="driver.lua"/> missing')
    doc = root.find("./config/documentation")
    if doc is None or doc.get("file") not in fileset:
        problems.append("<documentation file> missing or not packaged: %s" % (doc.get("file") if doc is not None else None))
    text = raw.decode("utf-8")
    refs = set()
    for m in re.finditer(r"controller://driver/([^/<\"]+)/([^<\"]+)", text):
        if m.group(1) != NAME:
            problems.append("controller:// URL uses %r, expected %r" % (m.group(1), NAME))
        refs.add("www/" + m.group(2))
    for m in re.finditer(r'image_source="c4z">([^<]+)<', text):
        refs.add("www/" + m.group(1).strip())
    for m in re.finditer(r'(?:small|large)_image="([^"]+)"', text):
        refs.add("www/" + m.group(1))
    for r in sorted(refs):
        if r.split("?")[0] not in fileset:
            problems.append("referenced file not packaged: " + r)
    if "www/index.html" not in fileset:
        problems.append("driver/www/index.html (web UI) is missing")
    if not root.findtext("./capabilities/web_view_url"):
        problems.append("capabilities/web_view_url missing")
    if problems:
        raise BuildError("driver.xml validation failed:\n  " + "\n  ".join(problems))
    return root, sorted(refs)


def validate_requires(files):
    luafiles = [f for f in files if f.endswith(".lua")]
    modules = {f[:-4].replace("/", ".") for f in luafiles}
    problems = []
    for f in luafiles:
        src = read(os.path.join(DRIVER, f))
        for m in re.finditer(r'require\s*\(?\s*["\']([\w.]+)["\']', src):
            mod = m.group(1)
            if mod not in modules and mod not in PLATFORM_MODULES:
                problems.append("%s: require(%r) does not resolve inside the c4z" % (f, mod))
    if problems:
        raise BuildError("\n".join(problems))
    return len(luafiles)


def stamp_xml(raw, version_int, modified):
    s = raw.decode("utf-8")
    s, n1 = re.subn(r"<version>[^<]*</version>", "<version>%d</version>" % version_int, s, count=1)
    s, n2 = re.subn(r"<modified>[^<]*</modified>", "<modified>%s</modified>" % modified, s, count=1)
    if n1 != 1 or n2 != 1:
        raise BuildError("driver.xml needs <version> and <modified> elements")
    ET.fromstring(s.encode("utf-8"))
    return s.encode("utf-8")


def stamp_version_lua(raw, build_date):
    s = raw.decode("utf-8")
    s, n = re.subn(r'M\.BUILD_DATE\s*=\s*"[^"]*"', 'M.BUILD_DATE = "%s"' % build_date, s, count=1)
    if n != 1:
        raise BuildError("c4/version.lua: BUILD_DATE not found")
    return s.encode("utf-8")


def write_c4zproj():
    top_dirs = sorted(d for d in os.listdir(DRIVER)
                      if os.path.isdir(os.path.join(DRIVER, d)) and d not in JUNK_DIRS and not d.startswith("."))
    lines = ['<Driver type="c4z" name="%s" squishLua="false" manualsquish="false">' % NAME, "  <Items>"]
    for d in top_dirs:
        lines.append('    <Item type="dir" name="%s" c4zDir="%s" recurse="true"/>' % (d, d))
    lines.append('    <Item type="file" name="driver.xml"/>')
    lines.append('    <Item type="file" name="driver.lua"/>')
    lines += ["  </Items>", "</Driver>", ""]
    content = "\n".join(lines)
    path = os.path.join(DRIVER, NAME + ".c4zproj")
    old = read(path) if os.path.exists(path) else None
    if old != content:
        with open(path, "w") as f:
            f.write(content)
    ET.fromstring(content)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="validate only, do not write the c4z")
    ap.add_argument("--out", default=os.path.join(ROOT, "build"), help="output directory (default build/)")
    ap.add_argument("--smoke", metavar="DIR", help="unzip the c4z into DIR (emptied first) and run the smoke test")
    args = ap.parse_args()

    try:
        version, version_int = version_info()
        files = collect_files()
        validate_xml(files)
        nlua = validate_requires(files)
    except BuildError as e:
        print("BUILD FAILED: %s" % e, file=sys.stderr)
        return 1

    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))
    tm = time.gmtime(epoch)
    modified = time.strftime("%m/%d/%Y %H:%M", tm)
    build_date = time.strftime("%Y-%m-%d", tm)
    zip_time = tuple(max(1980, tm.tm_year) if i == 0 else v for i, v in enumerate(tm[:6]))

    proj = write_c4zproj()
    print("Now Playing Info %s (driver.xml version %d), %d files, %d Lua modules" % (version, version_int, len(files), nlua))
    print("c4zproj: %s" % os.path.relpath(proj, ROOT))
    if args.check:
        print("check OK")
        return 0

    os.makedirs(args.out, exist_ok=True)
    out = os.path.join(args.out, NAME + ".c4z")
    tmp = out + ".tmp"
    total = 0
    rows = []
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in files:
            data = read(os.path.join(DRIVER, rel), "rb")
            if rel == "driver.xml":
                data = stamp_xml(data, version_int, modified)
            elif rel == "c4/version.lua":
                data = stamp_version_lua(data, build_date)
            info = zipfile.ZipInfo(rel, date_time=zip_time)
            info.compress_type = zipfile.ZIP_STORED if rel.endswith(".png") else zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
            total += len(data)
            rows.append((rel, len(data), hashlib.sha256(data).hexdigest()[:12]))
    os.replace(tmp, out)

    width = max(len(r[0]) for r in rows)
    print("\nManifest:")
    for rel, size, digest in rows:
        print("  %-*s %9d  %s" % (width, rel, size, digest))
    zsize = os.path.getsize(out)
    print("\n%d files, %d bytes uncompressed -> %s (%d bytes, sha256 %s)" % (
        len(rows), total, os.path.relpath(out, ROOT), zsize, hashlib.sha256(read(out, "rb")).hexdigest()[:16]))
    if args.smoke:
        return smoke(out, os.path.abspath(args.smoke))
    return 0


def smoke(c4z, dest):
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    with zipfile.ZipFile(c4z) as z:
        for n in z.namelist():
            if n.startswith("/") or ".." in n.split("/"):
                print("refusing suspicious path in zip: " + n, file=sys.stderr)
                return 1
        z.extractall(dest)
    script = os.path.join(ROOT, "tests", "c4", "c4z_smoke.lua")
    rc, ran = 0, 0
    for interp in ("lua5.1", "luajit"):
        exe = shutil.which(interp)
        if not exe:
            print("(%s not found, skipped)" % interp)
            continue
        ran += 1
        print("\n$ %s tests/c4/c4z_smoke.lua %s" % (interp, dest))
        rc |= subprocess.call([exe, script, dest], cwd=ROOT)
    if ran == 0:
        print("no Lua interpreter found; smoke test not run", file=sys.stderr)
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
