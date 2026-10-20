"""Verify startup and reader-exit sync against the owned DAV fixture."""
import copy
import hashlib
import json
import sys
import urllib.request
from pathlib import Path


def candidate(entities):
    key, revisions = next((k, r) for k, r in entities.items()
                          if k.startswith('position/') and r[0]['value']['sourceId'] == 'fixture-b')
    assert len(revisions) == 1
    remote = copy.deepcopy(revisions[0]['value'])
    assert remote['chapter']['url'].endswith('/3.html')
    remote['chapter'].update(url=remote['chapter']['url'].replace('/3.html', '/1.html'),
                             title='Chapter 1', number=None)
    remote.update(textOffset=0, quote='Chapter 1 opening paragraph.', prefix='', suffix='',
                  chapterDigest='', imageHash=None, imageUrl=None, updatedAt=4102444800000)
    return key, {'clock': {'automatic-ui-device': 1}, 'value': remote}


def verify(entities, before, key):
    revisions = entities[key]
    assert len(revisions) == 1, 'Same-source progress must resolve automatically'
    position = revisions[0]['value']
    assert position['chapter']['title'] == 'Chapter 3', 'Newer timestamp replaced further reading progress'
    assert position['sourceId'] == 'fixture-b'
    assert revisions[0]['clock']['automatic-ui-device'] == 1, 'Startup did not merge the remote revision'
    for device, counter in before[key][0]['clock'].items():
        assert revisions[0]['clock'][device] >= counter
    for old_key, old_value in before.items():
        if old_key != key:
            assert entities[old_key] == old_value, f'Unrelated record changed: {old_key}'


def main(stage):
    base = 'http://127.0.0.1:8765'
    manifest = Path('build/android-ui/auto-sync-manifest.json')
    with urllib.request.urlopen(base + '/fixture-state') as response:
        files = json.load(response)['files']
    heads = [json.loads(raw)['entities'] for name, raw in files.items()
             if name.startswith('/dav/kazumiSync/novels/') and name.endswith('.json')]
    assert len(heads) == 1
    entities = heads[0]
    if stage == 'inject':
        key, remote = candidate(entities)
        raw = json.dumps({'version': 1, 'entities': {key: [remote]}},
                         ensure_ascii=False, separators=(',', ':')).encode()
        name = '/dav/kazumiSync/novels/' + 'd' * 32 + '-' + hashlib.sha256(raw).hexdigest() + '.json'
        with urllib.request.urlopen(urllib.request.Request(base + name, data=raw, method='PUT')) as response:
            assert response.status == 201
        manifest.write_text(json.dumps({'key': key, 'before': entities}), encoding='utf-8')
    elif stage == 'verify':
        saved = json.loads(manifest.read_text(encoding='utf-8'))
        verify(entities, saved['before'], saved['key'])
    else:
        raise ValueError(stage)
    print(f'Native automatic sync {stage}: passed.')


if __name__ == '__main__':
    main(sys.argv[1])
