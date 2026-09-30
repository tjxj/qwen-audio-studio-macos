"use strict";
const { ipcRenderer } = require("electron");
ipcRenderer.once(
  "studio:decode",
  async (_event, { channel, data, sampleRate, channels }) => {
    try {
      const context = new OfflineAudioContext(channels, 1, sampleRate);
      const bytes = new Uint8Array(data);
      const audio = await context.decodeAudioData(bytes.buffer);
      ipcRenderer.send(channel, { duration: audio.duration });
    } catch {
      ipcRenderer.send(channel, { error: true });
    }
  },
);
