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
if stage == 'legacy':
    assert all('/v1/' in name for name in heads), 'Baseline did not use its actual legacy protocol'
elif stage == 'upgraded':
    assert len(heads) == 1 and all('/v1/' not in name for name in heads), 'Upgrade did not compact/migrate legacy heads'
    legacy = json.loads(Path('build/android-ui/upgrade-legacy-state.json').read_text(encoding='utf-8'))
    # The baseline may have written several immutable snapshots. Compare every
    # original non-position revision, not merely a same-named replacement mark.
    upgraded_entities = json.loads(next(iter(heads.values())))['entities']
    for old_name, old_raw in legacy['files'].items():
        if not old_name.endswith('.json') or '/novels/v1/' not in old_name:
            continue
        for key, old_revisions in json.loads(old_raw)['entities'].items():
            if key.startswith('position/'):
                old_position = old_revisions[0]['value']
                new_position = upgraded_entities[key][0]['value']
                for field in ('editionId', 'sourceId', 'chapter'):
                    assert new_position[field] == old_position[field], f'Upgrade changed original position {field}'
                for device, counter in old_revisions[0]['clock'].items():
                    assert upgraded_entities[key][0]['clock'][device] >= counter
            else:
                assert upgraded_entities[key] == old_revisions, f'Upgrade rebuilt or lost original data: {key}'
else:
    raise ValueError(stage)
for raw in heads.values():
    entities = json.loads(raw)['entities']
    assert all(len(revisions) == 1 for revisions in entities.values())
    marks = {revisions[0]['value']['note'] for key, revisions in entities.items()
             if key.startswith('bookmark/') and revisions[0]['value'] is not None}
    assert {'LegacyBookmark1', 'LegacyBookmark2'} <= marks, 'Upgrade lost a native bookmark'
    positions = [revisions[0]['value'] for key, revisions in entities.items() if key.startswith('position/')]
    assert positions and all(p['chapter']['title'] == 'Chapter 2' for p in positions), 'Upgrade lost native chapter-two progress'
    assert any(key.startswith('shelf/') and revisions[0]['value'] is not None
               for key, revisions in entities.items()), 'Upgrade lost bookshelf membership'
print(f'Native upgrade {stage}: verified signed app data, both bookmarks, chapter two and shelf.')
