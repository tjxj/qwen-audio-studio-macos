'use strict';

const INVALID_WAV = '音频不是完整有效的 PCM16 WAV 文件。';
const invalid = () => new Error(INVALID_WAV);
const validRate = value => Number.isInteger(value) && value >= 8000 && value <= 192000;
const validChannels = value => value === 1 || value === 2;

/** Inspect the whole RIFF container; declared chunk sizes never authorize out-of-bounds reads. */
function inspectWav(data) {
  if (!Buffer.isBuffer(data) || data.length < 44 || data.toString('latin1', 0, 4) !== 'RIFF' || data.toString('latin1', 8, 12) !== 'WAVE') throw invalid();
  const riffLength = data.readUInt32LE(4);
  if (riffLength !== 0xffffffff && riffLength !== data.length - 8) throw invalid();
  let cursor = 12;
  let format;
  let payload;
  while (cursor < data.length) {
    if (data.length - cursor < 8) throw invalid();
    const tag = data.toString('latin1', cursor, cursor + 4);
    const declaredSize = data.readUInt32LE(cursor + 4);
    const start = cursor + 8;
    // Streaming provider WAV uses the sentinel only for RIFF and final data.
    if (declaredSize === 0xffffffff && tag !== 'data') throw invalid();
    const size = declaredSize === 0xffffffff ? data.length - start : declaredSize;
    if (size > data.length - start) throw invalid();
    const end = start + size;
    const next = end + (size & 1);
    if (next > data.length) throw invalid();
    if (tag === 'fmt ') {
      if (format || size < 16 || size === 17) throw invalid();
      if (size >= 18 && data.readUInt16LE(start + 16) !== size - 18) throw invalid();
      const code = data.readUInt16LE(start);
      const channels = data.readUInt16LE(start + 2);
      const sampleRate = data.readUInt32LE(start + 4);
      const byteRate = data.readUInt32LE(start + 8);
      const blockAlign = data.readUInt16LE(start + 12);
      const bitsPerSample = data.readUInt16LE(start + 14);
      if (code !== 1 || bitsPerSample !== 16 || !validChannels(channels) || !validRate(sampleRate) || blockAlign !== channels * 2 || byteRate !== sampleRate * blockAlign) throw invalid();
      format = { channels, sampleRate, bitsPerSample, blockAlign };
    } else if (tag === 'data') {
      if (payload || size === 0) throw invalid();
      payload = { dataOffset: start, dataLength: size };
    }
    cursor = next;
  }
  if (!format || !payload || payload.dataLength % format.blockAlign !== 0) throw invalid();
  return {
    duration: payload.dataLength / format.blockAlign / format.sampleRate,
    sampleRate: format.sampleRate,
    channels: format.channels,
    bitsPerSample: format.bitsPerSample,
    ...payload,
  };
}

function header(dataLength, sampleRate, channels) {
  if (!validRate(sampleRate) || !validChannels(channels) || !Number.isSafeInteger(dataLength) || dataLength <= 0 || dataLength > 0xffffffff - 36 || dataLength % (channels * 2)) throw invalid();
  const result = Buffer.alloc(44);
  result.write('RIFF'); result.writeUInt32LE(dataLength + 36, 4);
  result.write('WAVEfmt ', 8); result.writeUInt32LE(16, 16);
  result.writeUInt16LE(1, 20); result.writeUInt16LE(channels, 22);
  result.writeUInt32LE(sampleRate, 24); result.writeUInt32LE(sampleRate * channels * 2, 28);
  result.writeUInt16LE(channels * 2, 32); result.writeUInt16LE(16, 34);
  result.write('data', 36); result.writeUInt32LE(dataLength, 40);
  return result;
}

/** Convert the caller's complete mono selection. Cropping must happen before this function. */
function encodeWav({ samples, sampleRate } = {}) {
  if (!(samples instanceof Float32Array) || samples.length === 0) throw invalid();
  const wavHeader = header(samples.length * 2, sampleRate, 1);
  const pcm = Buffer.allocUnsafe(samples.length * 2);
  for (let index = 0; index < samples.length; index++) {
    const sample = samples[index];
    if (!Number.isFinite(sample)) throw invalid();
    const scaled = Math.max(-1, Math.min(1, sample)) * 32767;
    // Swift .rounded() resolves half-way values away from zero, including negative samples.
    const rounded = Math.sign(scaled) * Math.round(Math.abs(scaled));
    pcm.writeInt16LE(rounded, index * 2);
  }
  return Buffer.concat([wavHeader, pcm]);
}

function wrapPCM(data, { sampleRate, channels } = {}) {
  if (!Buffer.isBuffer(data)) throw invalid();
  return Buffer.concat([header(data.length, sampleRate, channels), data]);
}

module.exports = { inspectWav, encodeWav, wrapPCM };
