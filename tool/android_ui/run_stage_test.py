import contextlib
import io
import runpy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_stage import run_stage


class RunStageTest(unittest.TestCase):
    def test_progress_and_detailed_output_are_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'stage.log'
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                result = run_stage('reading', log, [sys.executable, '-c',
                    "import time; print('tool detail'); time.sleep(0.1)"], interval=0.02)
            self.assertEqual(result, 0)
            self.assertIn('[RUNNING] reading', console.getvalue())
            self.assertIn('[PASS] reading', console.getvalue())
            self.assertNotIn('tool detail', console.getvalue())
            self.assertIn('tool detail', log.read_text(encoding='utf-8'))

    def test_failure_exit_code_and_prior_stage_log_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'stage.log'
            log.write_text('previous stage\n', encoding='utf-8')
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                result = run_stage('accounts', log, [sys.executable, '-c',
                    "import sys; print('assertion failed', file=sys.stderr); sys.exit(7)"])
            self.assertEqual(result, 7)
            self.assertIn('[FAIL] accounts', console.getvalue())
            detail = log.read_text(encoding='utf-8')
            self.assertIn('previous stage', detail)
            self.assertIn('assertion failed', detail)

    def test_cli_returns_the_command_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            script = str(Path(__file__).with_name('run_stage.py'))
            args = [script, 'upgrade', str(Path(directory) / 'stage.log'),
                    sys.executable, '-c', 'raise SystemExit(9)']
            console = io.StringIO()
            with patch.object(sys, 'argv', args), contextlib.redirect_stdout(console):
                with self.assertRaises(SystemExit) as exit_result:
                    runpy.run_path(script, run_name='__main__')
            self.assertEqual(exit_result.exception.code, 9)
            self.assertIn('[FAIL] upgrade', console.getvalue())


if __name__ == '__main__':
    unittest.main()
