"""Check native 0.1.1 writes, then the installed update's preservation/migration."""
import hashlib
import json
import re
import sys
from pathlib import Path

stage, file = sys.argv[1:]
state = json.loads(Path(file).read_text(encoding='utf-8'))
heads = {name: raw for name, raw in state['files'].items()
         if re.fullmatch(r'/dav/kazumiSync/novels/(?:v1/)?[0-9a-f]{32}-[0-9a-f]{64}\.json', name)}
assert heads, 'Installed baseline did not publish novel data'
for name, raw in heads.items():
    assert name.endswith('-' + hashlib.sha256(raw.encode()).hexdigest() + '.json')

def dominates(left, right):
    return all(left['clock'].get(device, 0) >= counter
               for device, counter in right['clock'].items())

def sequential_baseline(files):
    # The installed 0.1.1 seed has one writer and may publish many historical
    # heads. Compare its latest causal record, rather than every old position.
    entities = {}
    for raw in files.values():
        for key, revisions in json.loads(raw)['entities'].items():
            assert len(revisions) == 1, f'Baseline has concurrent candidates: {key}'
            revision = revisions[0]
            previous = entities.get(key)
            if previous is not None:
                assert dominates(revision, previous) or dominates(previous, revision), f'Baseline writes are concurrent: {key}'
                if revision['clock'] == previous['clock']:
                    assert revision == previous, f'Baseline has different values at the same clock: {key}'
                if not dominates(revision, previous):
                    continue
            entities[key] = revision
    return entities

if stage == 'legacy':
    assert all('/v1/' in name for name in heads), 'Baseline did not use its actual legacy protocol'
    verified_entities = {key: [revision] for key, revision in sequential_baseline(heads).items()}
elif stage == 'upgraded':
    assert len(heads) == 1 and all('/v1/' not in name for name in heads), 'Upgrade did not compact/migrate legacy heads'
    legacy = json.loads(Path('build/android-ui/upgrade-legacy-state.json').read_text(encoding='utf-8'))
    upgraded_entities = json.loads(next(iter(heads.values())))['entities']
    old_heads = {name: raw for name, raw in legacy['files'].items()
                 if re.fullmatch(r'/dav/kazumiSync/novels/v1/[0-9a-f]{32}-[0-9a-f]{64}\.json', name)}
    assert old_heads, 'Missing original baseline snapshots'
    for key, original in sequential_baseline(old_heads).items():
        assert len(upgraded_entities[key]) == 1, f'Upgrade introduced a conflict: {key}'
        current = upgraded_entities[key][0]
        if key.startswith('position/'):
            for field in ('editionId', 'sourceId', 'chapter', 'textOffset', 'quote', 'prefix', 'suffix', 'chapterDigest', 'imageHash'):
                assert current['value'][field] == original['value'][field], f'Upgrade changed original position {field}'
            assert dominates(current, original), f'Upgrade lost original causal history: {key}'
        else:
            assert current == original, f'Upgrade rebuilt or lost original data: {key}'
    verified_entities = upgraded_entities
else:
    raise ValueError(stage)
assert all(len(revisions) == 1 for revisions in verified_entities.values())
marks = {revisions[0]['value']['note'] for key, revisions in verified_entities.items()
             if key.startswith('bookmark/') and revisions[0]['value'] is not None}
assert {'LegacyBookmark1', 'LegacyBookmark2'} <= marks, 'Upgrade lost a native bookmark'
positions = [revisions[0]['value'] for key, revisions in verified_entities.items() if key.startswith('position/')]
assert positions and all(p['chapter']['title'] == 'Chapter 2' for p in positions), 'Upgrade lost native chapter-two progress'
assert all(p['textOffset'] > 0 for p in positions), 'Baseline/upgrade did not retain a nonzero text anchor'
assert any(key.startswith('shelf/') and revisions[0]['value'] is not None
           for key, revisions in verified_entities.items()), 'Upgrade lost bookshelf membership'
print(f'Native upgrade {stage}: verified signed app data, both bookmarks, chapter two and shelf.')
