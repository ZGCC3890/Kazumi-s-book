import json
import threading
import unittest
from http.cookiejar import CookieJar
from http.server import ThreadingHTTPServer
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, build_opener

import fixture_server


class QuietHandler(fixture_server.Handler):
    def log_message(self, *_):
        pass


class AccountFixtureTest(unittest.TestCase):
    def test_login_expiry_and_reauthentication_contract(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), QuietHandler)
        server.account_generation = 1
        server.account_logins = 0
        previous_base = fixture_server.BASE
        fixture_server.BASE = base = f'http://127.0.0.1:{server.server_port}'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = build_opener(HTTPCookieProcessor(CookieJar()))
        try:
            def get(path):
                return client.open(base + path)
            rule = json.load(get('/account/rule.json'))
            self.assertEqual(rule['login']['verifyUrl'], base + '/account/verify')
            self.assertEqual(get('/novels/L/search').url, base + '/account/required')
            data = urlencode({'username': 'fixture-reader', 'password': 'fixture-password'}).encode()
            client.open(base + '/account/login', data).close()
            self.assertIn(b'id="logout"', get('/account/verify').read())
            self.assertIn(b'Author L', get('/novels/L/search').read())
            get('/account/expire').close()
            self.assertNotIn(b'id="logout"', get('/account/verify').read())
            self.assertEqual(get('/novels/L/search').url, base + '/account/required')
            client.open(base + '/account/login', data).close()
            self.assertEqual(json.load(get('/account/state')), {'logins': 2})
            self.assertIn(b'Author L', get('/novels/L/search').read())
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
            fixture_server.BASE = previous_base


if __name__ == '__main__':
    unittest.main()
