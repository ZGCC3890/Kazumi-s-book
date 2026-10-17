import contextlib
import copy
import hashlib
import io
import json
import runpy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def owned_entities():
    def revision(value):
        return [{'value': value}]
    return {
        'position/book': revision({'sourceId': 'fixture-b'}),
        'shelf/book': revision({'title': 'Owned book'}),
        'bookmark/left': revision({'note': 'LeftMargin', 'position': {'textOffset': 5}}),
        'bookmark/right': revision({'note': 'RightMargin', 'position': {'textOffset': 10}}),
    }


def verify(entities, scope, *, legacy=False, bad_hash=False):
    raw = json.dumps({'entities': entities})
    digest = '0' * 64 if bad_hash else hashlib.sha256(raw.encode()).hexdigest()
    name = '/dav/kazumiSync/novels/' + 'a' * 32 + '-' + digest + '.json'
    state = {'files': {name: raw}, 'directories': ['/dav/kazumiSync/v1'] if legacy else []}
    script = Path(__file__).with_name('verify_sync.py')
    with tempfile.TemporaryDirectory() as temp:
        fixture = Path(temp) / 'state.json'
        fixture.write_text(json.dumps(state), encoding='utf-8')
        with patch.object(sys, 'argv', [str(script), str(fixture), scope]), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name='__main__')


class VerifySyncTest(unittest.TestCase):
    def test_owned_scope_requires_independent_novel_records(self):
        verify(owned_entities(), 'owned')
        entities = owned_entities()
        entities['anime/book'] = [{'value': {'id': 1}}]
        with self.assertRaisesRegex(AssertionError, 'Standalone'):
            verify(entities, 'owned')

    def test_full_scope_still_requires_the_real_association(self):
        with self.assertRaisesRegex(AssertionError, 'association'):
            verify(owned_entities(), 'full')
        entities = owned_entities()
        entities['anime/book'] = [{'value': {'id': 1}}]
        verify(entities, 'full')

    def test_unknown_scope_fails(self):
        with self.assertRaisesRegex(AssertionError, 'scope'):
            verify(owned_entities(), 'unknown')

    def test_corrupt_or_missing_native_records_still_fail(self):
        variants = []
        for key in ['position/book', 'shelf/book']:
            entities = owned_entities()
            entities[key] = [{'value': None}]
            variants.append(entities)
            entities = owned_entities()
            del entities[key]
            variants.append(entities)
        entities = owned_entities()
        entities['position/book'][0]['value']['sourceId'] = 'fixture-a'
        variants.append(entities)
        entities = owned_entities()
        entities['position/book'].append(copy.deepcopy(entities['position/book'][0]))
        variants.append(entities)
        for key in ['bookmark/left', 'bookmark/right']:
            entities = owned_entities()
            entities[key][0]['value']['position']['textOffset'] = 0
            variants.append(entities)
        for entities in variants:
            with self.subTest(entities=entities), self.assertRaises(AssertionError):
                verify(entities, 'owned')
        for options in [{'legacy': True}, {'bad_hash': True}]:
            with self.subTest(options=options), self.assertRaises(AssertionError):
                verify(owned_entities(), 'owned', **options)


if __name__ == '__main__':
    unittest.main()
