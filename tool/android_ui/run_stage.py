"""Report native test progress while keeping detailed tool output in an artifact."""
import subprocess
import sys
import time
from pathlib import Path


def run_stage(name, log_path, command, *, interval=30):
    started = time.monotonic()
    print(f'[START] {name}', flush=True)
    with Path(log_path).open('a', encoding='utf-8') as log:
        log.write(f'\n[STAGE] {name}\n')
        log.flush()
        with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT) as process:
            while True:
                try:
                    result = process.wait(timeout=interval)
                    break
                except subprocess.TimeoutExpired:
                    print(f'[RUNNING] {name}: {time.monotonic() - started:.0f}s', flush=True)
    status = 'PASS' if result == 0 else 'FAIL'
    print(f'[{status}] {name}: {time.monotonic() - started:.1f}s (exit {result})', flush=True)
    return result


if __name__ == '__main__':
    sys.exit(run_stage(sys.argv[1], sys.argv[2], sys.argv[3:]))
