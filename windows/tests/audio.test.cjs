'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { inspectWav, encodeWav, wrapPCM } = require('../src/core/audio.cjs');

function chunk(id, bytes, declared = bytes.length) {
  const head = Buffer.alloc(8); head.write(id); head.writeUInt32LE(declared, 4);
  return Buffer.concat([head, bytes, ...(bytes.length % 2 ? [Buffer.alloc(1)] : [])]);
}
function fixture({ channels = 1, sampleRate = 24000, frames = 24, extras = [], format = 1, bits = 16 } = {}) {
  const fmt = Buffer.alloc(16); fmt.writeUInt16LE(format); fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(sampleRate, 4); fmt.writeUInt32LE(sampleRate * channels * bits / 8, 8);
  fmt.writeUInt16LE(channels * bits / 8, 12); fmt.writeUInt16LE(bits, 14);
  const body = Buffer.concat([Buffer.from('WAVE'), chunk('fmt ', fmt), ...extras, chunk('data', Buffer.alloc(frames * channels * bits / 8))]);
  const head = Buffer.alloc(8); head.write('RIFF'); head.writeUInt32LE(body.length, 4);
  return Buffer.concat([head, body]);
}
function changed(buffer, offset, value, width = 4) {
  const copy = Buffer.from(buffer); copy[width === 2 ? 'writeUInt16LE' : 'writeUInt32LE'](value, offset); return copy;
}

test('inspects real mono/stereo PCM16 bytes and physical duration', () => {
  for (const channels of [1, 2]) {
    const data = fixture({ channels, frames: 48000, sampleRate: 48000 });
    assert.deepEqual(inspectWav(data), { duration: 1, sampleRate: 48000, channels, bitsPerSample: 16, dataOffset: 44, dataLength: 96000 * channels });
  }
});
test('accepts bounded provider streaming RIFF and data lengths', () => {
  const data = fixture({ frames: 360000 });
  for (const offsets of [[4], [40], [4, 40]]) {
    const streaming = Buffer.from(data); for (const offset of offsets) streaming.writeUInt32LE(0xffffffff, offset);
    assert.equal(inspectWav(streaming).duration, 15);
    assert.equal(inspectWav(streaming).dataLength, 720000);
  }
});
test('walks padded unknown chunks without losing data offsets', () => {
  const info = inspectWav(fixture({ extras: [chunk('JUNK', Buffer.from('abc')), chunk('LIST', Buffer.from('hello'))] }));
  assert.equal(info.dataOffset, 70); assert.equal(info.dataLength, 48);
});
test('rejects truncated file at every boundary without guessing missing bytes', () => {
  const data = fixture();
  for (let length = 0; length < data.length; length++) assert.throws(() => inspectWav(data.subarray(0, length)), undefined, `length ${length}`);
});
test('rejects incorrect fixed RIFF lengths, trailing bytes and incomplete chunk headers', () => {
  const data = fixture();
  for (const invalid of [changed(data, 4, data.length), changed(data, 4, data.length - 10), Buffer.concat([data, Buffer.from([0])])]) assert.throws(() => inspectWav(invalid));
  const trailing = Buffer.concat([data, Buffer.alloc(4)]); trailing.writeUInt32LE(trailing.length - 8, 4);
  assert.throws(() => inspectWav(trailing));
});
test('rejects oversized, truncated and unaligned chunks even with streaming container', () => {
  const data = changed(fixture(), 4, 0xffffffff);
  for (const invalid of [changed(data, 16, 0xffffffff), changed(data, 16, 999999), changed(data, 40, 1000), changed(data, 40, 47)]) assert.throws(() => inspectWav(invalid));
  const oddUnknown = fixture({ extras: [chunk('JUNK', Buffer.from('a'))] });
  const missingPad = Buffer.concat([oddUnknown.subarray(0, 45), oddUnknown.subarray(46)]);
  missingPad.writeUInt32LE(missingPad.length - 8, 4); assert.throws(() => inspectWav(missingPad));
});
test('rejects wrong tags, wrong buffer types and unsupported sample formats', () => {
  const wave = fixture();
  for (const data of [null, [], new Uint8Array(wave), Buffer.from('not a wave'), fixture({ format: 3, bits: 32 }), fixture({ bits: 8 })]) assert.throws(() => inspectWav(data));
  for (const offset of [0, 8]) { const invalid = Buffer.from(wave); invalid.write('NOPE', offset); assert.throws(() => inspectWav(invalid)); }
});
test('validates channels, sample rate, byte rate, frame alignment and nonempty data', () => {
  const data = fixture();
  for (const invalid of [changed(data, 22, 0, 2), changed(data, 22, 3, 2), changed(data, 24, 0), changed(data, 24, 7999), changed(data, 24, 192001), changed(data, 28, 2), changed(data, 32, 4, 2), fixture({ frames: 0 })]) assert.throws(() => inspectWav(invalid));
  const stereo = fixture({ channels: 2 });
  const partialFrame = stereo.subarray(0, stereo.length - 2);
  partialFrame.writeUInt32LE(partialFrame.length - 8, 4); partialFrame.writeUInt32LE(partialFrame.length - 44, 40);
  assert.throws(() => inspectWav(partialFrame));
});
test('rejects duplicate fmt or data chunks and missing required chunks', () => {
  const data = fixture();
  for (const addition of [data.subarray(12, 36), data.subarray(36)]) {
    const duplicate = Buffer.concat([data, addition]); duplicate.writeUInt32LE(duplicate.length - 8, 4); assert.throws(() => inspectWav(duplicate));
  }
  for (const tag of ['fmt ', 'data']) { const invalid = Buffer.from(data); invalid.write('JUNK', tag === 'fmt ' ? 12 : 36); assert.throws(() => inspectWav(invalid)); }
});
test('accepts PCM fmt extension only when its declared extension bytes exist', () => {
  const source = fixture();
  const extended = Buffer.concat([source.subarray(0, 36), Buffer.from([0, 0]), source.subarray(36)]);
  extended.writeUInt32LE(extended.length - 8, 4); extended.writeUInt32LE(18, 16);
  assert.equal(inspectWav(extended).dataOffset, 46);
  extended.writeUInt16LE(10, 36); assert.throws(() => inspectWav(extended));
});
test('encodes float samples as exact Swift-compatible little-endian mono PCM16', () => {
  const samples = new Float32Array([-2, -1, -0.5, 0, 0.5, 1, 2]);
  const data = encodeWav({ samples, sampleRate: 24000 });
  assert.deepEqual(inspectWav(data), { duration: 7 / 24000, sampleRate: 24000, channels: 1, bitsPerSample: 16, dataOffset: 44, dataLength: 14 });
  assert.deepEqual(Array.from({ length: 7 }, (_, index) => data.readInt16LE(44 + index * 2)), [-32767, -32767, -16384, 0, 16384, 32767, 32767]);
  assert.equal(samples[0], -2);
});
test('does not truncate float input or silently turn non-finite samples into silence', () => {
  for (const samples of [[], new Float64Array([1]), new Float32Array(), new Float32Array([NaN]), new Float32Array([Infinity])]) assert.throws(() => encodeWav({ samples, sampleRate: 24000 }));
  for (const sampleRate of [null, '24000', 0, 7999, 192001, 24000.5, Infinity]) assert.throws(() => encodeWav({ samples: new Float32Array([1]), sampleRate }));
  assert.equal(inspectWav(encodeWav({ samples: new Float32Array(24000 * 31), sampleRate: 24000 })).duration, 31);
});
test('wraps raw interleaved PCM16 unchanged in a newly owned buffer', () => {
  const pcm = Buffer.from([0, 0, 255, 127, 0, 128, 255, 255]);
  const data = wrapPCM(pcm, { sampleRate: 48000, channels: 2 });
  assert.deepEqual(data.subarray(44), pcm); assert.equal(inspectWav(data).duration, 2 / 48000);
  pcm.fill(0); assert.equal(data.readInt16LE(46), 32767);
});
test('rejects raw PCM incomplete frames, emptiness and invalid metadata', () => {
  for (const [data, options] of [[Buffer.alloc(0), {sampleRate:24000,channels:1}], [Buffer.alloc(3), {sampleRate:24000,channels:1}], [Buffer.alloc(6), {sampleRate:24000,channels:2}], [Buffer.alloc(4), {sampleRate:24000,channels:3}], [Buffer.alloc(4), {sampleRate:'24000',channels:1}], [new Uint8Array(4), {sampleRate:24000,channels:1}]]) assert.throws(() => wrapPCM(data, options));
});

test('container and chunk identifiers require exact ASCII bytes, not high-bit lookalikes', () => {
  for (const offset of [0, 8, 12, 36]) {
    const data = fixture(); data[offset] |= 0x80;
    assert.throws(() => inspectWav(data), undefined, `high bit at ${offset}`);
  }
});
