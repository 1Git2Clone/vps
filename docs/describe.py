"""Give every page of the built handbook its own description and link preview.

usage: python3 -I docs/describe.py <built book dir> <site url>

mdBook writes book.toml's one `description` into every page, and no Open Graph
tags at all, so every link to the handbook previewed (in Discord, in search
results) as "How one NixOS box and its CI runner are put together, and why."
whatever chapter it pointed at. mdBook has no per-chapter description, so this
runs after `mdbook build` and rewrites each page's head:

  * the description is the page's own `<!-- description: ... -->` comment
    when its markdown has one (mdBook passes HTML comments through), else the
    page's first paragraph, cut at a word boundary;
  * og:title / og:description / og:url / og:site_name and their twitter:
    equivalents are added, which is what link previews actually read.

Run by .forgejo/workflows/pages.yml, between the build and the upload.
"""
import html
import pathlib
import re
import sys
from html.parser import HTMLParser

book = pathlib.Path(sys.argv[1])
site = sys.argv[2].rstrip("/")
MAX = 200


class FirstParagraph(HTMLParser):
    """The text of the first <p> inside <main>."""

    def __init__(self):
        super().__init__()
        self.in_main = self.in_p = self.done = False
        self.text = []

    def handle_starttag(self, tag, _attrs):
        if tag == "main":
            self.in_main = True
        elif tag == "p" and self.in_main and not self.done:
            self.in_p = True

    def handle_endtag(self, tag):
        if tag == "p" and self.in_p:
            self.in_p, self.done = False, True

    def handle_data(self, data):
        if self.in_p:
            self.text.append(data)


def shorten(text):
    text = " ".join(text.split())
    if len(text) <= MAX:
        return text
    return text[: text.rfind(" ", 0, MAX - 1)].rstrip(",;:") + "…"


changed = 0
for page in sorted(book.rglob("*.html")):
    if page.name in ("print.html", "toc.html", "404.html"):
        continue
    src = page.read_text()
    own = re.search(r"<!--\s*description:\s*(.*?)\s*-->", src, re.S)
    if own:
        desc = shorten(own.group(1))
    else:
        p = FirstParagraph()
        p.feed(src)
        desc = shorten("".join(p.text))
    if not desc:
        continue
    found = re.search(r"<title>(.*?)</title>", src, re.S)
    if not found:
        sys.exit(f"describe.py: {page} has no <title>; did mdBook's theme change?")
    title = found.group(1).strip()
    page_title = html.unescape(title.rsplit(" - ", 1)[0])
    site_name = html.unescape(title.rsplit(" - ", 1)[-1])
    url = f"{site}/{page.relative_to(book).as_posix()}"
    if page.name == "index.html":
        url = url[: -len("index.html")]

    attr = lambda s: html.escape(s, quote=True)
    head = (
        f'<meta name="description" content="{attr(desc)}">\n'
        f'        <meta property="og:type" content="website">\n'
        f'        <meta property="og:site_name" content="{attr(site_name)}">\n'
        f'        <meta property="og:title" content="{attr(page_title)}">\n'
        f'        <meta property="og:description" content="{attr(desc)}">\n'
        f'        <meta property="og:url" content="{attr(url)}">\n'
        f'        <meta name="twitter:card" content="summary">\n'
        f'        <meta name="twitter:title" content="{attr(page_title)}">\n'
        f'        <meta name="twitter:description" content="{attr(desc)}">'
    )
    new, n = re.subn(r'<meta name="description" content="[^"]*">', head, src, count=1)
    if n != 1:
        sys.exit(f"describe.py: {page} has no description tag to replace; did mdBook's theme change?")
    page.write_text(new)
    changed += 1

if changed == 0:
    sys.exit("describe.py: rewrote no pages; refusing to pass vacuously")
print(f"describe.py: {changed} pages described")
