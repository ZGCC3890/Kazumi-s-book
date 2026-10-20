import copy
import unittest
from exercise_auto_sync import candidate, verify


class AutoSyncTest(unittest.TestCase):
    def test_newer_earlier_candidate_keeps_original_untouched(self):
        before = {'position/e': [{'clock': {'local': 4}, 'value': {
            'sourceId': 'fixture-b', 'chapter': {'url': 'https://fixture/B/3.html', 'title': 'Chapter 3'},
            'updatedAt': 100}}], 'bookmark/m': [{'clock': {'local': 2}, 'value': {'note': 'keep'}}]}
        original = copy.deepcopy(before)
        key, remote = candidate(before)
        self.assertEqual(before, original)
        self.assertEqual(remote['value']['chapter']['title'], 'Chapter 1')
        self.assertGreater(remote['value']['updatedAt'], before[key][0]['value']['updatedAt'])
        merged = copy.deepcopy(before)
        merged[key][0]['clock'] = {'local': 5, 'automatic-ui-device': 1}
        verify(merged, before, key)
        for field in ['chapter', 'sourceId']:
            broken = copy.deepcopy(merged)
            broken[key][0]['value'][field] = {'title': 'Chapter 1'} if field == 'chapter' else 'fixture-a'
            with self.assertRaises(AssertionError):
                verify(broken, before, key)
        for mutation in ['conflict', 'lost-clock', 'bookmark']:
            broken = copy.deepcopy(merged)
            if mutation == 'conflict': broken[key].append(remote)
            if mutation == 'lost-clock': broken[key][0]['clock']['local'] = 0
            if mutation == 'bookmark': broken['bookmark/m'] = []
            with self.assertRaises(AssertionError):
                verify(broken, before, key)
