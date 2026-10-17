const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const filename = path.resolve(__dirname, '../../.maestro/scripts/playback-sample.js');
const source = fs.readFileSync(filename, 'utf8');
function sample(text, { stage = 'before', mode = 'advancing', now = 1000, output = {} } = {}) {
  vm.runInNewContext(source, {
    maestro: { copiedText: text }, SAMPLE: stage, MODE: mode, PHASE: 'test',
    output, Date: { now: () => now }, console: { log() {} },
  }, { filename });
  return output;
}

test('advancing pattern includes only times at least three seconds later', () => {
  const output = sample('00:15 / 02:00');
  assert.equal(output.firstPosition, 15);
  const pattern = new RegExp(output.progressPattern.replace('(?s)', ''), 's');
  for (const [text, expected] of [['00:17', false], ['00:18', true], ['01:59', true], ['02:00', false]]) {
    assert.equal(pattern.test(text + ' / 02:00'), expected);
  }
  sample('00:18 / 02:00', { stage: 'after', output, now: 4000 });
});

for (const label of ['missing time', '00:00 / 02:00', '02:00 / 02:00']) {
  test('rejects invalid or completed playback: ' + label, () => assert.throws(() => sample(label)));
}
test('requires enough remaining clip time', () => {
  assert.throws(() => sample('01:57 / 02:00'), /Insufficient/);
  sample('01:56 / 02:00');
});
test('rejects a stationary or insufficiently advanced playing video', () => {
  const output = sample('00:15 / 02:00');
  assert.throws(() => sample('00:17 / 02:00', { stage: 'after', output }), /did not advance/);
});
test('paused samples must all keep the same position', () => {
  const output = sample('01:59 / 02:00', { mode: 'steady' });
  sample('01:59 / 02:00', { stage: 'after', mode: 'steady', output, now: 6000 });
  assert.throws(() => sample('01:58 / 02:00', { stage: 'after', mode: 'steady', output }), /Paused/);
});
test('enforces the ten-second observation limit', () => {
  const output = sample('00:15 / 02:00');
  sample('00:18 / 02:00', { stage: 'after', output, now: 11000 });
  assert.throws(() => sample('00:18 / 02:00', { stage: 'after', output, now: 11001 }), /exceeded/);
});

test('playback flow asserts the distinct playing and paused episode semantics', () => {
  const flow = fs.readFileSync(path.resolve(__dirname, '../../.maestro/assert-owned-playback.yaml'), 'utf8');
  const expressions = [...flow.matchAll(/^- assertVisible: "\$\{(.+)\}"$/gm)].map(match => match[1]);
  assert.equal(expressions.length, 2);
  for (const expression of expressions) {
    assert.equal(vm.runInNewContext(expression, { EPISODE: '1', MODE: 'steady' }), 'Episode 1，当前选集');
    assert.equal(vm.runInNewContext(expression, { EPISODE: '1', MODE: 'advancing' }), 'Episode 1，正在播放');
    assert.equal(vm.runInNewContext(expression, { EPISODE: '2', MODE: 'advancing' }), 'Episode 2，正在播放');
  }
});
