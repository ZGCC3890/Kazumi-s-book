"""Finite, owned content for Android black-box flows; no user credentials/data."""
import argparse
import json
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

BASE = "http://10.0.2.2:8765"
REPO = Path(__file__).resolve().parents[2]


def novel_rule(letter):
    with (REPO / "novel_rules/linovel.json").open(encoding="utf-8") as source:
        rule = json.load(source)
    rule.update(id=f"fixture-{letter.lower()}", name=f"Fixture Source {letter}",
                edition="UI fixture", revision="1", headers={"Referer": BASE + "/"},
                searchUrl=f"{BASE}/novels/{letter}/search?kw=@keyword",
                directBookUrlPattern=r"^http://10\.0\.2\.2:8765/novels/[ABC]/book\.html$")
    return rule


def video_rule():
    return dict(api="9", type="anime", name="Fixture Video", version="1.0",
                muliSources=True, useWebview=False, useNativePlayer=True, usePost=False,
                useLegacyParser=False, adBlocker=False, userAgent="", baseURL=BASE + "/",
                searchURL="", searchList="", searchName="", searchResult="",
                chapterRoads="", chapterResult="", referer="", searchMode="api", chapterMode="api",
                searchApiConfig={"request": {"method": "GET", "url": BASE + "/anime/search", "query": {"q": "@keyword"}},
                                 "listPath": "$.data[*]", "namePath": "$.name", "sourcePath": "$.id"},
                chapterApiConfig={"request": {"method": "GET", "url": BASE + "/anime/book/@source"},
                                  "format": "nested", "roadsPath": "$.data.roads[*]", "roadNamePath": "$.name",
                                  "episodesPath": "$.episodes[*]", "episodeNamePath": "$.name", "episodeUrlPath": "$.url"})


def png():
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    pixels = (b"\0" + b"\x55\x77\xaa" * 256) * 256
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def send(self, content, kind="text/html; charset=utf-8", status=200):
        body = content.encode() if isinstance(content, str) else content
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/novels/rules.json":
            return self.send(json.dumps([novel_rule("A"), novel_rule("C")]), "application/json")
        if path == "/novels/catalog.json":
            return self.send(json.dumps({"version": 1, "rules": [{"id": "fixture-b", "name": "Fixture Source B",
                "file": "B.json", "description": "Owned fixture for repeatable chapter matching."}]}), "application/json")
        if path == "/novels/B.json":
            return self.send(json.dumps(novel_rule("B")), "application/json")
        if path == "/video-rule.json":
            return self.send(json.dumps(video_rule()), "application/json")
        if path in ("/cover.png", "/illustration.png"):
            return self.send(png(), "image/png")
        parts = path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "novels" and parts[1] in ("A", "B", "C"):
            letter, page = parts[1:]
            if page == "search":
                return self.send(f'<a class="search-book" href="/novels/{letter}/book.html">'
                    f'<div class="book-name">Fixture Book</div><div class="book-extra">Author {letter} 丨 owned content</div>'
                    '<div class="book-cover"><img src="/cover.png"></div></a>')
            if page == "book.html":
                return self.send('<h1 class="book-title">Fixture Book</h1><h2 class="volume-title">Volume 1</h2>'
                    + ''.join(f'<div class="chapter"><a href="/novels/{letter}/{i}.html">Chapter {i}</a></div>' for i in range(1, 4)))
            if page in ("1.html", "2.html", "3.html"):
                chapter = int(page[0])
                return self.send('<div class="article-text">'
                    + f'<p>Chapter {chapter} opening paragraph.</p><img src="/illustration.png">'
                    + ''.join(f'<p>Chapter {chapter} paragraph {i}. Owned text for scrolling and paging. '
                              'Reading should preserve this exact location when settings change.</p>' for i in range(1, 31))
                    + '</div>')
        if path == "/anime/search":
            return self.send(json.dumps({"data": [{"name": "葬送的芙莉莲", "id": "1"}]}), "application/json")
        if path == "/anime/book/1":
            return self.send(json.dumps({"data": {"roads": [{"name": "Fixture Road", "episodes": [
                {"name": "Episode 1", "url": BASE + "/clip.mp4"},
                {"name": "Episode 2", "url": BASE + "/clip.mp4"}]}]}}), "application/json")
        if path == "/clip.mp4":
            return self.send((self.server.output / "clip.mp4").read_bytes(), "video/mp4")
        self.send("Unregistered fixture path", "text/plain", 404)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "video-rule.json").write_text(json.dumps(video_rule()), encoding="utf-8")
    server = ThreadingHTTPServer(("0.0.0.0", 8765), Handler)
    server.output = args.output
    server.serve_forever()


if __name__ == "__main__":
    main()
