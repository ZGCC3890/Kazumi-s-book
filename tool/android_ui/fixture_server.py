"""Finite, owned content for Android black-box flows; no user credentials/data."""
import argparse
import html
import json
import re
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from video_frames import probe

BASE = "http://10.0.2.2:8765"
REPO = Path(__file__).resolve().parents[2]


def novel_rule(letter):
    with (REPO / "novel_rules/linovel.json").open(encoding="utf-8") as source:
        rule = json.load(source)
    rule.update(id=f"fixture-{letter.lower()}", name=f"Fixture Source {letter}",
                edition="UI fixture", revision="1", headers={"Referer": BASE + "/"},
                searchUrl=f"{BASE}/novels/{letter}/search?kw=@keyword",
                directBookUrlPattern=rf"^{re.escape(BASE)}/novels/[ABC]/book\.html$")
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


def account_rule():
    rule = novel_rule('L')
    rule.update(name='Fixture Account', loginRequiredUrlPattern=re.escape(BASE) + '/account/required',
        login=dict(url=BASE + '/account/login', usernameField='username', passwordField='password',
                   fields={}, verifyUrl=BASE + '/account/verify', verifySelector='#logout'))
    return rule


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

    def dav_path(self):
        path = urlsplit(self.path).path.rstrip('/')
        return path if path == '/dav' or path.startswith('/dav/') else None

    def do_POST(self):
        if urlsplit(self.path).path != '/account/login':
            return self.send('Unknown POST', 'text/plain', 404)
        fields = parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        if fields != {'username': ['fixture-reader'], 'password': ['fixture-password']}:
            return self.send('Invalid account', 'text/plain')
        self.server.account_logins += 1
        self.send_response(200)
        self.send_header('Set-Cookie', f'account={self.server.account_generation}; Path=/; HttpOnly')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_OPTIONS(self):
        if self.dav_path() is None:
            return self.send('Unsupported OPTIONS', 'text/plain', 405)
        self.send_response(200)
        self.send_header('DAV', '1, 2')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_MKCOL(self):
        path = self.dav_path()
        if path is None or path.rsplit('/', 1)[0] not in self.server.directories:
            return self.send('Missing collection', 'text/plain', 409)
        status = 405 if path in self.server.directories else 201
        self.server.directories.add(path)
        self.send(b'', 'text/plain', status)

    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        path = self.dav_path()
        if path not in self.server.directories:
            return self.send('Missing collection', 'text/plain', 404)

        def entry(name):
            directory = name in self.server.directories
            href = html.escape(name + ('/' if directory else ''))
            length = 0 if directory else len(self.server.files[name])
            return (f'<d:response><d:href>{href}</d:href><d:propstat><d:prop>'
                    f'<d:resourcetype>{"<d:collection/>" if directory else ""}</d:resourcetype>'
                    f'<d:getcontentlength>{length}</d:getcontentlength></d:prop>'
                    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')

        children = sorted(name for name in self.server.directories | self.server.files.keys()
                          if name != path and name.rsplit('/', 1)[0] == path)
        xml = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
               + entry(path) + ''.join(map(entry, children)) + '</d:multistatus>')
        self.send(xml, 'application/xml; charset=utf-8', 207)

    def do_PUT(self):
        path = self.dav_path()
        if path is None or path.rsplit('/', 1)[0] not in self.server.directories:
            return self.send('Missing collection', 'text/plain', 409)
        self.server.files[path] = self.rfile.read(int(self.headers['Content-Length']))
        self.send(b'', 'text/plain', 201)

    def do_MOVE(self):
        path = self.dav_path()
        target = urlsplit(self.headers['Destination']).path.rstrip('/')
        if path not in self.server.files:
            return self.send('Missing file', 'text/plain', 404)
        if target in self.server.files:
            return self.send('Immutable head exists', 'text/plain', 412)
        self.server.files[target] = self.server.files.pop(path)
        self.send(b'', 'text/plain', 201)

    def do_DELETE(self):
        path = self.dav_path()
        if path in self.server.directories:
            return self.send('Collection deletion forbidden', 'text/plain', 405)
        status = 204 if self.server.files.pop(path, None) is not None else 404
        self.send(b'', 'text/plain', status)

    def do_HEAD(self):
        if urlsplit(self.path).path != '/clip.mp4':
            return self.send('Unsupported HEAD', 'text/plain', 404)
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str((self.server.output / 'clip.mp4').stat().st_size))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/account/rule.json':
            return self.send(json.dumps(account_rule()), 'application/json')
        if path == '/account/expire':
            self.server.account_generation += 1
            return self.send('expired', 'text/plain')
        if path == '/account/state':
            return self.send(json.dumps({'logins': self.server.account_logins}), 'application/json')
        if path == '/account/verify' or path.startswith('/novels/L/'):
            authenticated = self.headers.get('Cookie') == f'account={self.server.account_generation}'
            if path == '/account/verify':
                return self.send('<a id="logout">Logout</a>' if authenticated else '<form>Login</form>')
            if not authenticated:
                self.send_response(302)
                self.send_header('Location', '/account/required')
                self.send_header('Content-Length', '0')
                return self.end_headers()
        if path == '/account/required':
            return self.send('<form>Login required</form>')
        if self.dav_path() is not None:
            content = self.server.files.get(self.dav_path())
            if content is None:
                return self.send('Missing file', 'text/plain', 404)
            return self.send(content, 'application/octet-stream')
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
        if len(parts) == 3 and parts[0] == "novels" and parts[1] in ("A", "B", "C", "L"):
            letter, page = parts[1:]
            if page == "search":
                return self.send(f'<a class="search-book" href="/novels/{letter}/book.html">'
                    f'<div class="book-name">葬送的芙莉莲</div><div class="book-extra">Author {letter} 丨 owned content</div>'
                    '<div class="book-cover"><img src="/cover.png"></div></a>')
            if page == "book.html":
                return self.send('<h1 class="book-title">葬送的芙莉莲</h1><h2 class="volume-title">Volume 1</h2>'
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
            content = (self.server.output / 'clip.mp4').read_bytes()
            if 'Range' in self.headers:
                start, end = self.headers['Range'].removeprefix('bytes=').split('-')
                start = int(start)
                end = int(end) if end else len(content) - 1
                self.send_response(206)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(content)}')
                self.send_header('Content-Length', str(end - start + 1))
                self.end_headers()
                self.wfile.write(content[start:end + 1])
                return
            return self.send(content, 'video/mp4')
        if path == '/video-frame-progress':
            return self.send(json.dumps(probe(self.server.output)), 'application/json')
        if path == '/fixture-state':
            return self.send(json.dumps({
                'files': {name: content.decode() for name, content in self.server.files.items()},
                'directories': sorted(self.server.directories),
            }), 'application/json')
        self.send("Unregistered fixture path", "text/plain", 404)


def main():
    global BASE
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-url", default=BASE)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    BASE = args.base_url
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "video-rule.json").write_text(json.dumps(video_rule()), encoding="utf-8")
    server = ThreadingHTTPServer((args.host, 8765), Handler)
    server.output = args.output
    server.files = {}
    server.directories = {'/dav'}
    server.account_generation = 1
    server.account_logins = 0
    server.serve_forever()


if __name__ == "__main__":
    main()
