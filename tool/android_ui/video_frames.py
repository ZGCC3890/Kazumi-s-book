"""Measure rendered owned-video motion, independent of accessibility clocks."""
import json
import subprocess
import time


def pixels(png):
    # Central video region excludes transport controls, subtitles and system UI.
    return subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(png),
        '-vf', 'crop=iw*0.5:ih*0.4:iw*0.25:ih*0.3,scale=128:72',
        '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1',
    ], check=True, capture_output=True, timeout=3).stdout


def measure(first, second):
    assert len(first) == len(second) == 128 * 72 * 3, 'Incomplete video samples'
    count = len(first) // 3
    changed = sum(max(abs(first[i + c] - second[i + c]) for c in range(3)) > 20
                  for i in range(0, len(first), 3))
    lit = [sum(max(frame[i:i + 3]) > 32 for i in range(0, len(frame), 3)) / count
           for frame in (first, second)]
    return {'changedFraction': changed / count, 'firstLit': lit[0], 'secondLit': lit[1]}


def probe(output):
    folder = output.parent / 'playback-frames'
    folder.mkdir(exist_ok=True)
    stamp = str(time.monotonic_ns())
    started = time.monotonic()
    frames = []
    for index in range(2):
        if index:
            time.sleep(3)
        png = folder / f'{stamp}-{index}.png'
        png.write_bytes(subprocess.run(['adb', 'exec-out', 'screencap', '-p'],
                        check=True, capture_output=True, timeout=3).stdout)
        frames.append(pixels(png))
    result = measure(*frames)
    result['elapsedSeconds'] = time.monotonic() - started
    (folder / f'{stamp}.json').write_text(json.dumps(result), encoding='utf-8')
    return result
