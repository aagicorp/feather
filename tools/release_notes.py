#!/usr/bin/env python3
"""Turns one version's section of CHANGELOG.md into the small HTML page Sparkle shows in the update window.

usage: release_notes.py <version> <CHANGELOG.md> <out.html>      (exit status 1 when the version has no section)
"""
import html
import re
import sys


def inline(text):
    text = html.escape(text.replace("\\\\", "\\"))
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def main():
    version, source, out = sys.argv[1:4]
    lines = open(source, encoding="utf-8").read().splitlines()
    # "## 0.14.5" or "## 0.14.5 (required)": the marker makes release.sh mark the update critical; the notes leave it out.
    heading = re.compile(r"^## " + re.escape(version) + r"( \(required\))?\s*$")
    try:
        start = next(i for i, line in enumerate(lines) if heading.match(line.strip()))
    except StopIteration:
        return 1
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    body, in_list = ["<h2>Feather %s</h2>" % html.escape(version)], False
    for line in lines[start + 1:end]:
        item = re.match(r"\s*[-*] (.*)", line)
        if item:
            if not in_list:
                body.append("<ul>")
                in_list = True
            body.append("<li>" + inline(item.group(1)))
            continue
        if in_list and line.startswith("  ") and line.strip():        # a wrapped bullet
            body[-1] += " " + inline(line.strip())
            continue
        if in_list:
            body.append("</ul>")
            in_list = False
        if line.startswith("### "):
            body.append("<h3>" + inline(line[4:]) + "</h3>")
        elif line.strip():
            body.append("<p>" + inline(line.strip()) + "</p>")
    if in_list:
        body.append("</ul>")
    style = "body{font:13px -apple-system,sans-serif;margin:14px}h2{font-size:17px}h3{font-size:13px;margin:14px 0 4px}" \
            "ul{margin:0;padding-left:18px}li{margin:3px 0}code{font:12px ui-monospace,monospace}"
    open(out, "w", encoding="utf-8").write("<style>%s</style>\n%s\n" % (style, "\n".join(body)))
    return 0


sys.exit(main())
