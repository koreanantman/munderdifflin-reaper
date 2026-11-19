#!/usr/bin/env python3
"""Writes index.xml for ReaPack. Usage: gen_index.py <commit-sha>"""
import sys, re, datetime, urllib.parse
from xml.sax.saxutils import escape

OWNER_REPO = "koreanantman/munderdifflin-reaper"
CATEGORY = "Munder Difflin"
PACKAGE = "munderdifflin_Reception.lua"

sha = sys.argv[1]
src = open(f"{CATEGORY}/{PACKAGE}", encoding="utf-8").read()

def tag(name):
    m = re.search(rf"^-- @{name}[ \t]+(.+)$", src, re.M)
    return m.group(1).strip() if m else ""

def block(name):
    m = re.search(rf"^-- @{name}[ \t]*\n((?:--   .*\n|--\n)+)", src, re.M)
    if not m: return []
    return [re.sub(r"^--(   )?", "", l) for l in m.group(1).splitlines()]

provides = [l.split("]", 1)[1].strip() if "]" in l else l.strip() for l in block("provides") if l.strip()]
about = "\n".join(block("about")).strip()

# ReaPack shows the package description as RTF (reapack-index normally converts Markdown with pandoc)
def rtf(md):
    def esc(t):
        t = t.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
        return "".join(c if ord(c) < 128 else "\\u%d?" % ord(c) for c in t)
    out = [r"{\rtf1\ansi\deff0{\fonttbl{\f0 \fswiss Helvetica;}}\f0\fs20"]
    for line in md.splitlines():
        line = line.rstrip()
        if line.startswith("#"):
            out.append(r"{\b\fs28 " + esc(line.lstrip("#").strip()) + r"}\par")
        elif line == "":
            out.append(r"\par")
        else:
            out.append(esc(line) + r"\par")
    out.append("}")
    return "\n".join(out)
about = rtf(about)
def url(f):
    return f"https://github.com/{OWNER_REPO}/raw/{sha}/" + urllib.parse.quote(f"{CATEGORY}/{f}")

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
sources = [PACKAGE] + provides
out = ['<?xml version="1.0" encoding="utf-8"?>',
       '<index version="1" name="Munder Difflin" commit="%s">' % sha,
       '  <category name="%s">' % escape(CATEGORY),
       '    <reapack name="%s" type="script" desc="%s">' % (PACKAGE, escape(tag("description"), {'"': "&quot;"})),
       '      <metadata>',
       '        <description><![CDATA[%s]]></description>' % about,
       '        <link rel="website">https://github.com/%s</link>' % OWNER_REPO,
       '      </metadata>',
       '      <version name="%s" author="%s" time="%s">' % (tag("version"), escape(tag("author")), now),
       '        <changelog><![CDATA[%s]]></changelog>' % tag("changelog")]
for f in sources:
    out.append('        <source main="main" file="%s">%s</source>' % (escape(f), escape(url(f))))
out += ['      </version>', '    </reapack>', '  </category>',
        '  <metadata>',
        '    <link rel="website">https://github.com/%s</link>' % OWNER_REPO,
        '  </metadata>',
        '</index>', '']
open("index.xml", "w", encoding="utf-8").write("\n".join(out))
print("index.xml written for", tag("version"), "with", len(sources), "files")
