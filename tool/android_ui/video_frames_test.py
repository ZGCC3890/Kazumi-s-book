import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import video_frames
from fixture_server import Handler


class VideoFramesTest(unittest.TestCase):
    def test_motion_and_static_and_black(self):
        red = bytes([255, 0, 0]) * (128 * 72)
        green = bytes([0, 255, 0]) * (128 * 72)
        self.assertEqual(video_frames.measure(red, green),
                         dict(changedFraction=1, firstLit=1, secondLit=1))
        self.assertEqual(video_frames.measure(red, red)['changedFraction'], 0)
        self.assertEqual(video_frames.measure(bytes(len(red)), red)['firstLit'], 0)
        self.assertEqual(video_frames.measure(bytes([250, 0, 0]) * (128 * 72), red)['changedFraction'], 0)

    def test_incomplete_capture_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'Incomplete'):
            video_frames.measure(b'', b'')

    def test_probe_captures_two_frames_and_keeps_evidence(self):
        red = bytes([255, 0, 0]) * (128 * 72)
        green = bytes([0, 255, 0]) * (128 * 72)
        with tempfile.TemporaryDirectory() as temp, \
                patch('video_frames.subprocess.run', side_effect=[
                    SimpleNamespace(stdout=b'png1'), SimpleNamespace(stdout=red),
                    SimpleNamespace(stdout=b'png2'), SimpleNamespace(stdout=green)]) as run, \
                patch('video_frames.time.sleep') as sleep, \
                patch('video_frames.time.monotonic', side_effect=[10, 14]):
            result = video_frames.probe(Path(temp) / 'fixtures')
            self.assertEqual(result['elapsedSeconds'], 4)
            sleep.assert_called_once_with(3)
            self.assertEqual(len(run.call_args_list), 4)
            folder = Path(temp) / 'playback-frames'
            self.assertEqual(len(list(folder.glob('*.png'))), 2)
            self.assertEqual(json.loads(next(folder.glob('*.json')).read_text()), result)
            self.assertIn('crop=iw*0.5:ih*0.4:iw*0.25:ih*0.3,scale=128:72', run.call_args_list[1].args[0])

    def test_capture_and_decode_failures_propagate(self):
        for failing_call in (0, 1):
            with self.subTest(failing_call=failing_call), tempfile.TemporaryDirectory() as temp, \
                    patch('video_frames.subprocess.run', side_effect=[
                        *[SimpleNamespace(stdout=b'png')] * failing_call,
                        subprocess.CalledProcessError(1, 'capture')]):
                with self.assertRaises(subprocess.CalledProcessError):
                    video_frames.probe(Path(temp) / 'fixtures')

    def test_fixture_endpoint_returns_actual_probe_measurement(self):
        handler = object.__new__(Handler)
        handler.path = '/video-frame-progress'
        handler.server = SimpleNamespace(output=Path('fixtures'))
        sent = []
        handler.send = lambda body, kind: sent.append((json.loads(body), kind))
        result = dict(changedFraction=0.4, firstLit=1, secondLit=1, elapsedSeconds=4)
        with patch('fixture_server.probe', return_value=result) as probe:
            handler.do_GET()
        probe.assert_called_once_with(handler.server.output)
        self.assertEqual(sent, [(result, 'application/json')])


if __name__ == '__main__':
    unittest.main()
