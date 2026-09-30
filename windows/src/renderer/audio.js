(function (root) {
  "use strict";
  function encodeSelection(buffer, start, end) {
    if (
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      start < 0 ||
      end <= start ||
      end > buffer.duration + 0.00001 ||
      end - start > 30.00001
    )
      throw new Error("请选择有效的起止时间，片段长度须大于 0 且不超过 30 秒");
    const first = Math.floor(start * buffer.sampleRate);
    const last = Math.min(buffer.length, Math.floor(end * buffer.sampleRate));
    const frames = last - first;
    if (
      frames < 1 ||
      !Number.isFinite(buffer.sampleRate) ||
      buffer.sampleRate < 8000 ||
      buffer.sampleRate > 192000 ||
      buffer.numberOfChannels < 1
    )
      throw new Error("无法处理该音频采样格式");
    const bytes = new Uint8Array(44 + frames * 2);
    const view = new DataView(bytes.buffer);
    const text = (offset, value) => {
      for (let i = 0; i < value.length; i++)
        view.setUint8(offset + i, value.charCodeAt(i));
    };
    text(0, "RIFF");
    view.setUint32(4, bytes.length - 8, true);
    text(8, "WAVE");
    text(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, buffer.sampleRate, true);
    view.setUint32(28, buffer.sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    text(36, "data");
    view.setUint32(40, frames * 2, true);
    const channels = Array.from({ length: buffer.numberOfChannels }, (_, i) =>
      buffer.getChannelData(i),
    );
    for (let i = 0; i < frames; i++) {
      let sample = 0;
      for (const channel of channels)
        sample += channel[first + i] / channels.length;
      sample = Math.max(-1, Math.min(1, Number.isFinite(sample) ? sample : 0));
      view.setInt16(
        44 + i * 2,
        Math.round(sample * (sample < 0 ? 32768 : 32767)),
        true,
      );
    }
    return bytes;
  }
  async function decode(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (!bytes.byteLength || bytes.byteLength > 50 * 1024 * 1024)
      throw new Error("音频文件必须小于 50 MiB");
    const context = new AudioContext();
    try {
      const buffer = await context.decodeAudioData(
        bytes.buffer.slice(
          bytes.byteOffset,
          bytes.byteOffset + bytes.byteLength,
        ),
      );
      if (
        !Number.isFinite(buffer.duration) ||
        buffer.duration <= 0 ||
        buffer.duration > 600
      )
        throw new Error("源音频长度须在 0 至 10 分钟之间");
      return buffer;
    } catch (error) {
      throw new Error(
        error.message || "无法解码音频，请尝试 WAV、MP3、M4A 或 OGG 文件",
      );
    } finally {
      await context.close();
    }
  }
  function drawWaveform(canvas, buffer, start, end) {
    const ctx = canvas.getContext("2d");
    const width = canvas.width;
    const height = canvas.height;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = "#f1f0e9";
    ctx.fillRect(0, 0, width, height);
    ctx.fillStyle = "#dae7db";
    ctx.fillRect(
      (start / buffer.duration) * width,
      0,
      ((end - start) / buffer.duration) * width,
      height,
    );
    const samples = buffer.getChannelData(0);
    const stride = Math.max(1, Math.floor(samples.length / width));
    ctx.strokeStyle = "#487259";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 0; x < width; x += 2) {
      let peak = 0;
      const offset = Math.floor((x / width) * samples.length);
      for (let j = offset; j < Math.min(samples.length, offset + stride); j++)
        peak = Math.max(peak, Math.abs(samples[j]));
      const amplitude = Math.max(1, peak * (height / 2 - 8));
      ctx.moveTo(x, height / 2 - amplitude);
      ctx.lineTo(x, height / 2 + amplitude);
    }
    ctx.stroke();
  }
  const api = { encodeSelection, decode, drawWaveform };
  root.AudioTools = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
