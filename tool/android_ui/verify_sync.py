"""Inspect only the owned DAV fixture after real installed-app operations."""
import hashlib
import json
import re
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
heads = {name: raw for name, raw in state['files'].items()
         if re.fullmatch(r'/dav/kazumiSync/novels/[0-9a-f]{32}-[0-9a-f]{64}\.json', name)}
assert len(heads) == 1, f'Expected one compacted novel head, got {list(heads)}'
name, raw = next(iter(heads.items()))
assert name.endswith('-' + hashlib.sha256(raw.encode()).hexdigest() + '.json')
entities = json.loads(raw)['entities']
assert all(len(revisions) == 1 for revisions in entities.values()), 'Unexpected unresolved fixture conflict'
positions = [revisions[0]['value'] for key, revisions in entities.items() if key.startswith('position/')]
assert positions, 'Reader progress was not synchronized'
assert all(position is not None for position in positions), 'Reader progress was deleted'
shelves = [revisions[0]['value'] for key, revisions in entities.items() if key.startswith('shelf/')]
assert shelves and all(shelf is not None for shelf in shelves), 'Bookshelf was not synchronized'
bookmarks = {revisions[0]['value']['note']: revisions[0]['value']['position']
             for key, revisions in entities.items()
             if key.startswith('bookmark/') and revisions[0]['value'] is not None}
assert bookmarks['LeftMargin']['textOffset'] > 0, 'Left blank margin swipe did not advance reading'
assert bookmarks['RightMargin']['textOffset'] > bookmarks['LeftMargin']['textOffset'], 'Right blank margin swipe did not advance reading'
assert not any('/v1' in directory for directory in state['directories']), 'New installation created a legacy folder'
print('Installed app synchronized a verified flat novel head with progress and bookshelf.')
