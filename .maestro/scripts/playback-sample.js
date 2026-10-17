var timeMatch = maestro.copiedText.match(/(\d{2}):(\d{2}) \/ 02:00/);
if (!timeMatch) throw new Error('Owned video time label is missing');
var position = Number(timeMatch[1]) * 60 + Number(timeMatch[2]);
if (position <= 0 || position >= 120) throw new Error('Owned video must be between 0 and 120 seconds');

if (SAMPLE === 'before') {
    if (MODE === 'advancing' && position > 116) throw new Error('Insufficient clip time for an advancing sample');
    output.firstPosition = position;
    output.startedAt = Date.now();
    var times = [];
    for (var second = position + 3; second < 120; second++) {
        times.push(('0' + Math.floor(second / 60)).slice(-2) + ':' + ('0' + second % 60).slice(-2));
    }
    output.progressPattern = '(?s).*(' + times.join('|') + ') / 02:00.*';
} else {
    if (Date.now() - output.startedAt > 10000) throw new Error('Playback observation exceeded 10 seconds');
    if (MODE === 'steady') {
        if (position !== output.firstPosition) throw new Error('Paused playback advanced');
    } else if (position < output.firstPosition + 3) {
        throw new Error('Playback did not advance by three seconds');
    }
    console.log(PHASE + ' TIME GREEN: ' + MODE + ' [' + output.firstPosition + ', ' + position + ']');
}
