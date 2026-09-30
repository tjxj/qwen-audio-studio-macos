'use strict';
const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_AUDIO_BYTES = 100 * 1024 * 1024;
class ProviderError extends Error {
  constructor(code, message, { uncertain = false, status } = {}) {
    super(message); this.name = 'ProviderError'; this.code = code; this.uncertain = uncertain;
    if (status !== undefined) this.status = status;
  }
}
function validWorkspaceID(value) {
  return typeof value === 'string' && value.length <= 63 && /^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$/.test(value);
}
function secureURL(value) {
  let url; try { url = new URL(value); } catch { throw new ProviderError('invalid_response', '音频链接响应无效。', { uncertain: true }); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash) throw new ProviderError('invalid_response', '音频链接响应无效，必须使用 HTTPS。', { uncertain: true });
  return url;
}
async function limitedBytes(response, limit) {
  const declared = response.headers?.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > limit)) throw new Error('body limit');
  if (!response.body?.getReader) {
    const value = Buffer.from(await response.arrayBuffer());
    if (value.length > limit) throw new Error('body limit');
    return value;
  }
  const reader = response.body.getReader();
  const chunks = []; let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > limit) throw new Error('body limit');
      chunks.push(Buffer.from(value));
    }
  } catch (error) { try { await reader.cancel(); } catch {} throw error; }
  finally { reader.releaseLock(); }
  return Buffer.concat(chunks, total);
}
async function deadline(timeoutMs, action) {
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('timeout')); }, timeoutMs);
  });
  try { return await Promise.race([action(controller.signal), timeout]); }
  finally { clearTimeout(timer); }
}
async function synthesize({ workspaceID, apiKey, body, fetchImpl = fetch, timeoutMs = 300000 }) {
  if (!validWorkspaceID(workspaceID) || typeof apiKey !== 'string' || !apiKey.trim() || /[\r\n]/.test(apiKey)) {
    throw new ProviderError('invalid_request', '工作空间 ID 或 API Key 无效。');
  }
  let encoded;
  try { encoded = JSON.stringify(body); if (!encoded) throw new Error(); }
  catch { throw new ProviderError('invalid_request', '生成参数无法序列化。'); }
  const endpoint = `https://${workspaceID}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer`;
  try {
    return await deadline(timeoutMs, async signal => {
      const response = await fetchImpl(endpoint, { method: 'POST', redirect: 'error', signal,
        headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json', Accept: 'application/json' }, body: encoded });
      if (response.redirected || (response.url && response.url !== endpoint)) throw new ProviderError('invalid_response', '服务响应来源发生变化，生成结果未确认。', { uncertain: true });
      if (response.status !== 200) throw new ProviderError('http_error', `服务返回 HTTP ${Number(response.status) || 0}；生成结果未确认，请核查记录。`, { uncertain: true, status: Number(response.status) || 0 });
      let parsed;
      try { parsed = JSON.parse((await limitedBytes(response, MAX_RESPONSE_BYTES)).toString('utf8')); }
      catch { throw new ProviderError('invalid_response', '服务响应不完整，生成结果未确认。', { uncertain: true }); }
      const requestID = parsed?.request_id;
      const value = parsed?.output?.audio;
      if (typeof requestID !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(requestID) || !value || !Number.isFinite(value.expires_at) || value.expires_at <= Date.now() / 1000) {
        throw new ProviderError('invalid_response', '服务响应不完整或已过期，生成结果未确认。', { uncertain: true });
      }
      const url = secureURL(value.url);
      return { requestID, audioURL: url.href, expiresAt: value.expires_at };
    });
  } catch (error) {
    if (error instanceof ProviderError) throw error;
    throw new ProviderError('transport', '网络请求结果未能确认，不会自动重新提交，请在记录中核查。', { uncertain: true });
  }
}
async function download({ audioURL, expiresAt, fetchImpl = fetch, timeoutMs = 60000 }) {
  const url = secureURL(audioURL);
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now() / 1000) throw new ProviderError('expired_download', '下载链接已过期，未重新提交生成。');
  try {
    return await deadline(timeoutMs, async signal => {
      const response = await fetchImpl(url.href, { method: 'GET', redirect: 'error', signal, headers: { Accept: 'audio/*,application/octet-stream' } });
      if (response.status !== 200 || response.redirected || (response.url && response.url !== url.href)) throw new Error('download status');
      const data = await limitedBytes(response, MAX_AUDIO_BYTES);
      if (!data.length) throw new Error('empty audio');
      return data;
    });
  } catch { throw new ProviderError('download_failed', '音频下载失败，可单独重试下载，不会重新生成。'); }
}
module.exports = { ProviderError, validWorkspaceID, synthesize, download };
