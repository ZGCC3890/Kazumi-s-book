"""Inject and inspect concurrency only in the owned, local DAV fixture."""
import copy
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

BASE = 'http://127.0.0.1:8765'
MANIFEST = Path('build/android-ui/conflict-manifest.json')


def heads():
    with urllib.request.urlopen(BASE + '/fixture-state') as response:
        files = json.load(response)['files']
    return {name: json.loads(raw) for name, raw in files.items()
            if name.startswith('/dav/kazumiSync/novels/') and name.endswith('.json')}


stage = sys.argv[1]
current = heads()
assert len(current) == 1, f'Expected one compacted head at {stage}: {list(current)}'
entities = next(iter(current.values()))['entities']
if stage == 'inject':
    key, revisions = next((key, revisions) for key, revisions in entities.items()
                          if key.startswith('position/') and revisions[0]['value']['sourceId'] == 'fixture-b')
    assert len(revisions) == 1
    remote = copy.deepcopy(revisions[0]['value'])
    remote['sourceId'] = 'fixture-a'
    remote['bookUrl'] = remote['bookUrl'].replace('/B/', '/A/')
    remote['chapter'].update(url=remote['chapter']['url'].replace('/B/', '/A/').replace('/2.html', '/3.html'),
                             title='Chapter 3', number=None)
    assert remote['chapter']['url'].endswith('/3.html')
    remote.update(textOffset=0, quote='Chapter 3 opening paragraph.', prefix='', suffix='',
                  chapterDigest='', imageHash=None, updatedAt=1792219000000)
    remote_revision = {'clock': {'remote-ui-device': 1}, 'value': remote}
    raw = json.dumps({'version': 1, 'entities': {key: [remote_revision]}},
                     ensure_ascii=False, separators=(',', ':')).encode()
    name = '/dav/kazumiSync/novels/' + 'e' * 32 + '-' + hashlib.sha256(raw).hexdigest() + '.json'
    request = urllib.request.Request(BASE + name, data=raw, method='PUT')
    with urllib.request.urlopen(request) as response:
        assert response.status == 201
    MANIFEST.write_text(json.dumps({'key': key, 'before': entities, 'remote': remote_revision}), encoding='utf-8')
    print('Injected a cross-source remote chapter-three revision into the owned DAV fixture.')
else:
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
    key = manifest['key']
    revisions = entities[key]
    if stage == 'cancelled':
        assert len(revisions) == 2, 'Cancel discarded a concurrent revision'
        assert manifest['remote'] in revisions
        assert manifest['before'][key][0] in revisions
    elif stage == 'resolved':
        assert len(revisions) == 1, 'Explicit selection did not resolve the position'
        assert revisions[0]['value']['chapter']['title'] == 'Chapter 3'
        assert revisions[0]['clock']['remote-ui-device'] == 1
        original_clock = manifest['before'][key][0]['clock']
        for device, counter in original_clock.items():
            assert revisions[0]['clock'][device] >= counter, f'Resolution forgot {device}'
        assert any(revisions[0]['clock'][device] > counter for device, counter in original_clock.items()), 'Local resolution revision did not advance'
        assert revisions[0]['value']['editionId'] == manifest['remote']['value']['editionId']
        assert revisions[0]['value']['sourceId'] == 'fixture-b', 'Reader must restore the chosen progress in its selected source'
        assert revisions[0]['value']['chapter']['url'] == manifest['remote']['value']['chapter']['url'].replace('/A/', '/B/')
    else:
        raise ValueError(stage)
    for before_key, before_value in manifest['before'].items():
        if before_key != key:
            assert entities[before_key] == before_value, f'Unrelated record changed: {before_key}'
    print(f'Native conflict {stage}: verified candidates, causal clocks and all unrelated records.')
