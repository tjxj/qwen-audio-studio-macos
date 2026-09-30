const test = require("node:test");
const assert = require("node:assert/strict");
let audio;
try {
  audio = require("../src/renderer/audio.js");
} catch {
  audio = {};
}
const buffer = (seconds = 2, sampleRate = 8000) => ({
  sampleRate,
  length: seconds * sampleRate,
  duration: seconds,
  numberOfChannels: 2,
  getChannelData: (channel) =>
    new Float32Array(seconds * sampleRate).fill(channel ? 0.5 : 1),
});
test("renderer crop produces valid mono PCM16 WAV from explicit range", () => {
  assert.equal(typeof audio.encodeSelection, "function");
  const wav = audio.encodeSelection(buffer(), 0.5, 1.5);
  const view = new DataView(wav.buffer);
  assert.equal(Buffer.from(wav.slice(0, 4)).toString(), "RIFF");
  assert.equal(view.getUint16(22, true), 1);
  assert.equal(view.getUint32(24, true), 8000);
  assert.equal(view.getUint32(40, true), 16000);
  assert.equal(view.getInt16(44, true), 24575);
});
test("renderer rejects implicit, invalid and oversized crop selections", () => {
  assert.equal(typeof audio.encodeSelection, "function");
  for (const [start, end] of [
    [0, 31],
    [-1, 1],
    [1, 1],
    [2, 1],
    [0, Infinity],
    [NaN, 2],
    [0, 61],
  ])
    assert.throws(() => audio.encodeSelection(buffer(60), start, end));
});
test("renderer clamps samples and supports full sub-30-second clips", () => {
  assert.equal(typeof audio.encodeSelection, "function");
  const b = buffer(1);
  b.numberOfChannels = 1;
  b.getChannelData = () => new Float32Array(8000).fill(-2);
  const wav = audio.encodeSelection(b, 0, 1);
  assert.equal(new DataView(wav.buffer).getInt16(44, true), -32768);
});
test("source decoding limits bytes before creating an AudioContext", async () => {
  const previous = global.AudioContext;
  global.AudioContext = class {
    constructor() {
      throw Error("must not construct");
    }
  };
  try {
    await assert.rejects(audio.decode(new Uint8Array()), /50 MiB/);
    await assert.rejects(
      audio.decode(new Uint8Array(50 * 1024 * 1024 + 1)),
      /50 MiB/,
    );
  } finally {
    global.AudioContext = previous;
  }
});
test("decoding closes AudioContext on success and rejects >10-minute source", async () => {
  const previous = global.AudioContext;
  let closed = 0;
  let duration = 3;
  global.AudioContext = class {
    async decodeAudioData() {
      return { duration };
    }
    async close() {
      closed++;
    }
  };
  try {
    assert.equal((await audio.decode(new Uint8Array([1, 2]))).duration, 3);
    duration = 601;
    await assert.rejects(audio.decode(new Uint8Array([1, 2])), /10 分钟/);
    assert.equal(closed, 2);
  } finally {
    global.AudioContext = previous;
  }
});
test("decode failure closes context and reports the codec error", async () => {
  const previous = global.AudioContext;
  let closed = false;
  global.AudioContext = class {
    async decodeAudioData() {
      throw Error("unsupported codec");
    }
    async close() {
      closed = true;
    }
  };
  try {
    await assert.rejects(
      audio.decode(new Uint8Array([1])),
      /unsupported codec/,
    );
    assert.equal(closed, true);
  } finally {
    global.AudioContext = previous;
  }
});
