import contextlib
import copy
import io
import json
import runpy
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name('exercise_conflict.py').resolve()


class ConflictFixtureTest(unittest.TestCase):
    def test_selected_english_chapter_round_trips_through_reader_and_sync(self):
        original = {'clock': {'local-ui-device': 1}, 'value': {
            'editionId': 'owned-book', 'sourceId': 'fixture-b',
            'chapter': {'url': 'http://10.0.2.2:8765/novels/B/2.html',
                        'title': 'Chapter 2', 'volume': 'Volume 1', 'kind': '正文', 'number': None},
        }}
        entities = {'position/owned-book': [original],
                    'shelf/owned-book': [{'clock': {'local-ui-device': 1}, 'value': {'title': 'Owned book'}}]}
        uploaded = []

        def urlopen(request):
            if isinstance(request, urllib.request.Request):
                self.assertEqual(request.get_method(), 'PUT')
                uploaded.append(json.loads(request.data))
                response = io.BytesIO()
                response.status = 201
                return response
            raw = json.dumps({'entities': entities})
            return io.BytesIO(json.dumps({'files': {'/dav/kazumiSync/novels/head.json': raw}}).encode())

        def stage(name):
            with patch.object(sys, 'argv', [str(SCRIPT), name]), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(SCRIPT), run_name='__main__')

        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp), \
                patch('urllib.request.urlopen', side_effect=urlopen):
            Path('build/android-ui').mkdir(parents=True)
            stage('inject')
            remote = uploaded[0]['entities']['position/owned-book'][0]
            canonical_chapter = dict(original['value']['chapter'],
                                     url='http://10.0.2.2:8765/novels/B/3.html', title='Chapter 3')
            self.assertEqual(remote['value']['chapter'], canonical_chapter)
            entities['position/owned-book'] = [original, remote]
            stage('cancelled')
            selected = copy.deepcopy(remote)
            selected['clock']['local-ui-device'] = 2
            selected['value']['chapter'] = canonical_chapter
            entities['position/owned-book'] = [selected]
            stage('resolved')
            with self.assertRaises(ValueError):
                stage('unknown')
