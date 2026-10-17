var response = http.get('http://127.0.0.1:8765/video-frame-progress');
if (response.status !== 200) throw new Error('Native video sampling failed: ' + response.status);
var frames = JSON.parse(response.body);
if (!(frames.elapsedSeconds >= 3 && frames.elapsedSeconds <= 10)) throw new Error('Video observation must take 3–10 seconds');
if (!(frames.firstLit > 0.2 && frames.secondLit > 0.2)) throw new Error('Video frame is black');
if (!(frames.changedFraction > 0.01)) throw new Error('Rendered video did not advance');
console.log('RENDERED VIDEO GREEN: ' + response.body);
