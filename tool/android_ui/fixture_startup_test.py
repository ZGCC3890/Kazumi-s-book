import json
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.request import urlopen

import fixture_server


class FixtureStartupTest(unittest.TestCase):
    def test_ready_signal_is_written_after_socket_and_state_are_initialized(self):
        for ready_enabled in [True, False]:
            with self.subTest(ready_enabled=ready_enabled), tempfile.TemporaryDirectory() as directory:
                ready = Path(directory) / 'ready'
                args = ['fixture_server.py', '--output', directory, '--host', '127.0.0.1']
                if ready_enabled:
                    args += ['--ready-file', str(ready)]
                real_serve = ThreadingHTTPServer.serve_forever

                def check_running(server):
                    self.assertEqual(ready.exists(), ready_enabled)
                    if ready_enabled:
                        self.assertEqual(ready.read_text(encoding='utf-8'), '8765')
                    thread = threading.Thread(target=real_serve, args=(server,), daemon=True)
                    thread.start()
                    try:
                        with urlopen('http://127.0.0.1:8765/fixture-state', timeout=2) as response:
                            self.assertEqual(json.load(response), {'files': {}, 'directories': ['/dav']})
                    finally:
                        server.shutdown()
                        thread.join()
                        server.server_close()

                with patch.object(sys, 'argv', args), patch.object(
                        ThreadingHTTPServer, 'serve_forever', check_running):
                    fixture_server.main()


if __name__ == '__main__':
    unittest.main()
