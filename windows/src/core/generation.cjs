'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const domain = require('./domain.cjs');
const audio = require('./audio.cjs');
const defaultProvider = require('./provider.cjs');
const clone = value => structuredClone(value);
const digest = value => createHash('sha256').update(value).digest('hex');
const CONSENT_MS = 600000;
const MAX_AUDIO_BYTES = 100 * 1024 * 1024;
function under(parent, file) {
  const relative = path.relative(parent, file);
  return relative !== '' && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}
function writeAtomic(file, data) {
  const temp = `${file}.${randomUUID()}.tmp`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeFileSync(fd, data); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    fs.renameSync(temp, file);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try { fs.unlinkSync(temp); } catch {}
  }
}
function checkedReceipt(receipt) {
  let url;
  try { url = new URL(receipt.audioURL); } catch { throw new Error('响应无效'); }
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(receipt.requestID || '') || url.protocol !== 'https:' || url.username || url.password || url.hash || !Number.isFinite(receipt.expiresAt) || receipt.expiresAt <= Date.now()/1000) throw new Error('响应无效');
  return { requestID: receipt.requestID, audioURL: url.href, expiresAt: receipt.expiresAt };
}
// Structural precheck only. Successful MP3 output additionally requires the
// independently injected Chromium decoder; headers never prove decodability.
function inspectMP3(bytes, params) {
  let offset = 0;
  if (bytes.length >= 10 && bytes.toString('ascii', 0, 3) === 'ID3') {
    if (![2,3,4].includes(bytes[3]) || bytes.subarray(6,10).some(value => value & 0x80)) throw new Error('MP3 ID3 无效');
    const size = (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    offset = 10 + size + ((bytes[3] === 4 && bytes[5] & 0x10) ? 10 : 0);
  }
  let frames = 0;
  while (offset + 4 <= bytes.length) {
    if (bytes.length-offset === 128 && bytes.toString('ascii', offset, offset+3) === 'TAG') { offset=bytes.length; break; }
    const a=bytes[offset], b=bytes[offset+1], c=bytes[offset+2], d=bytes[offset+3];
    const version=(b>>3)&3, layer=(b>>1)&3, bitrateIndex=c>>4, rateIndex=(c>>2)&3;
    if (a!==255 || (b&0xe0)!==0xe0 || version===1 || layer!==1 || bitrateIndex===0 || bitrateIndex===15 || rateIndex===3) throw new Error('MP3 帧头无效');
    const rates=[44100,48000,32000];
    const sampleRate=rates[rateIndex]/(version===3?1:version===2?2:4);
    const bitrates=version===3?[0,32,40,48,56,64,80,96,112,128,160,192,224,256,320]:[0,8,16,24,32,40,48,56,64,80,96,112,128,144,160];
    const bitrate=bitrates[bitrateIndex]; const channels=(d>>6)===3?1:2;
    const frameSize=Math.floor((version===3?144000:72000)*bitrate/sampleRate)+((c>>1)&1);
    if (sampleRate!==params.sampleRate || channels!==params.channels || offset+frameSize>bytes.length || frameSize<4) throw new Error('MP3 音频参数或帧长度不匹配');
    offset+=frameSize; frames++;
  }
  if (frames<2 || offset!==bytes.length) throw new Error('MP3 无完整连续音频帧');
  return { duration: null, durationVerified: false, validation: '已校验 MPEG 帧结构；未进行解码或时长验证' };
}
function validateAudio(bytes, params, mode) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length>MAX_AUDIO_BYTES) throw new Error('音频内容为空或超出上限');
  const maxDuration=mode==='podcast'?240:120;
  if (params.format==='mp3') return inspectMP3(bytes, params);
  let info;
  if (params.format==='pcm') {
    if (bytes.length%(params.channels*2)) throw new Error('PCM 帧未对齐');
    info={duration:bytes.length/(params.sampleRate*params.channels*2),sampleRate:params.sampleRate,channels:params.channels};
  } else { info=audio.inspectWav(bytes); }
  if (info.sampleRate!==params.sampleRate || info.channels!==params.channels || info.duration<=0 || info.duration>maxDuration) throw new Error('音频参数或时长不匹配');
  return { duration: info.duration, durationVerified: true, validation: params.format==='pcm'?'已验证 PCM 帧长度与时长':'已验证 PCM WAV 结构与时长' };
}

class GenerationService {
  constructor({ store, credentials, provider = defaultProvider, outputDirectory, onChange = () => {}, now = Date.now, decodeAudio }) {
    if (!store || typeof credentials !== 'function') throw new Error('生成服务缺少本地存储或凭据读取器。');
    this.store=store; this.credentials=credentials; this.provider=provider; this.outputDirectory=outputDirectory; this.onChange=onChange; this.now=now; this.decodeAudio=decodeAudio;
    this.plans=new Map(); this.submitted=new Map(); this.retries=new Map(); this.active=0;
  }
  get isBusy() { return this.active>0; }
  preflight(draft, candidates=1) {
    const compiled=domain.compilePrompt(draft);
    const params=domain.validateParams(draft.params);
    const seeds=domain.candidateSeeds(params.seed,candidates);
    const credentials=this.credentials();
    if (!defaultProvider.validWorkspaceID(credentials.workspaceID) || typeof credentials.apiKey!=='string' || !credentials.apiKey.trim() || /[\r\n]/.test(credentials.apiKey)) throw new Error('请先在设置中保存有效的 API Key 和 Workspace ID。');
    const root=typeof this.outputDirectory==='function'?this.outputDirectory():this.outputDirectory || this.store.snapshot().settings.outputDirectory;
    if (typeof root!=='string' || !root) throw new Error('请先选择输出目录。');
    const outputDirectory=fs.realpathSync(root);
    if (!fs.statSync(outputDirectory).isDirectory()) throw new Error('输出目录不可用。');
    fs.accessSync(outputDirectory, fs.constants.W_OK);
    const library=this.store.snapshot().references;
    const references=compiled.bindings.map(binding=>this._reference(library,binding));
    for (const seed of seeds) domain.makeRequest({prompt:compiled.text,params,seed,references});
    const now=this.now();
    for (const [token, plan] of this.plans) if (plan.expiresAt<=now) this.plans.delete(token);
    if (this.plans.size>=16) this.plans.delete(this.plans.keys().next().value);
    const token=randomUUID();
    const plan={token,prompt:compiled.text,params:clone(params),seeds:[...seeds],references,
      outputDirectory,workspaceID:credentials.workspaceID,createdAt:now,expiresAt:now+CONSENT_MS,
      draft:{name:String(draft.name || '未命名作品').slice(0,200),mode:draft.mode,prompt:draft.prompt,params:clone(params),bindings:clone(compiled.bindings)}};
    this.plans.set(token,plan);
    return {token,prompt:plan.prompt,params:clone(params),seeds:[...seeds],references:references.map(({id,slot,name,duration})=>({id,slot,name,duration})),outputDirectory,calls:seeds.length,expiresAt:plan.expiresAt};
  }
  _reference(library, binding) {
    const reference=library.find(item=>item.id===binding.referenceID && !item.deleted && !item.trashed);
    try {
      if (!reference || typeof reference.path!=='string') throw new Error();
      const root=fs.realpathSync(path.join(this.store.directory,'references'));
      const file=fs.realpathSync(reference.path);
      if (!under(root,file)) throw new Error();
      const size=fs.statSync(file).size;
      if (size<44 || size>10*1024*1024 || reference.mimeType!=='audio/wav') throw new Error();
      const bytes=fs.readFileSync(file);
      const info=audio.inspectWav(bytes);
      if (info.channels!==1 || info.bitsPerSample!==16 || info.duration<=0 || info.duration>30 || !Number.isFinite(reference.duration) || Math.abs(info.duration-reference.duration)>0.1 || digest(bytes)!==reference.contentHash) throw new Error();
      return {id:reference.id,slot:binding.slot,name:reference.name,duration:info.duration,contentHash:reference.contentHash,mimeType:'audio/wav',data:Buffer.from(bytes)};
    } catch { throw new Error('参考音频不可用或内容已变化，请重新准备并确认。'); }
  }
  cancelPreflight(token) { return this.plans.delete(token); }
  submit(token) {
    if (typeof token!=='string' || token.length>128) throw new Error('确认已失效，请重新预检。');
    if (this.submitted.has(token)) return this.submitted.get(token);
    const submissionID=digest(token);
    const existing=this.store.snapshot().tasks.filter(task=>task.submissionID===submissionID);
    if (existing.length) {
      const result=Promise.resolve({tasks:existing}); this.submitted.set(token,result); return result;
    }
    const plan=this.plans.get(token);
    if (!plan || plan.expiresAt<=this.now()) {this.plans.delete(token);throw new Error('确认已过期或失效，请重新预检。');}
    if (this.isBusy) throw new Error('已有生成或下载任务正在执行，请稍候。');
    this.plans.delete(token); this.active++;
    const promise=Promise.resolve().then(()=>this._executeBatch(plan,submissionID)).finally(()=>{this.active--;this._emit();});
    this.submitted.set(token,promise); this._emit(); return promise;
  }
  async _executeBatch(plan,submissionID) {
    const credentials=this.credentials();
    if (credentials.workspaceID!==plan.workspaceID || !credentials.apiKey) throw new Error('工作空间凭据已变化，请重新预检确认。');
    this._checkDirectory(plan.outputDirectory);
    const batchID=randomUUID(); const createdAt=new Date(this.now()).toISOString();
    const tasks=plan.seeds.map((seed,index)=>{
      const id=randomUUID(); const directory=path.join(plan.outputDirectory,id);
      const body=domain.makeRequest({prompt:plan.prompt,params:plan.params,seed,references:plan.references});
      return {id,batchID,submissionID,index,name:plan.draft.name,mode:plan.draft.mode,prompt:plan.prompt,params:clone(plan.params),seed,status:'preparing',createdAt,updatedAt:createdAt,
        directory,outputDirectory:plan.outputDirectory,requestHash:digest(JSON.stringify(body)),
        snapshot:{draft:clone(plan.draft),prompt:plan.prompt,params:clone(plan.params),seed,workspaceID:plan.workspaceID,outputDirectory:plan.outputDirectory,
          references:plan.references.map(({data,...reference})=>clone(reference)),confirmedAt:createdAt,consentExpiresAt:plan.expiresAt}};
    });
    for (const task of tasks) fs.mkdirSync(task.directory,{mode:0o700});
    // One durable transaction owns the entire batch before the first paid POST.
    this.store.update(data=>{data.tasks.unshift(...tasks);}); this._emit();
    for (const task of tasks) {
      if (this.now()>=plan.expiresAt) {this._patch(task.id,{status:'failed',error:'上传确认已过期，此候选未发送。'});continue;}
      let body;
      try {
        this._checkDirectory(task.outputDirectory,task.directory);
        body=domain.makeRequest({prompt:plan.prompt,params:plan.params,seed:task.seed,references:plan.references});
        if (digest(JSON.stringify(body))!==task.requestHash) throw new Error('确认快照校验失败');
      } catch {
        this._patch(task.id,{status:'failed',error:'输出目录或确认快照不可用，此候选未发送。'});
        continue;
      }
      this._patch(task.id,{status:'requesting'});
      let receipt;
      try { receipt=checkedReceipt(await this.provider.synthesize({workspaceID:credentials.workspaceID,apiKey:credentials.apiKey,body})); }
      catch { this._patch(task.id,{status:'uncertain',error:'生成请求结果未能确认，可能已产生费用；不会自动重发，请核查服务记录。'}); continue; }
      this._patch(task.id,{status:'downloading',receipt,providerRequestID:receipt.requestID});
      await this._finishDownload(this._task(task.id));
    }
    return {tasks:tasks.map(task=>this._task(task.id))};
  }
  retryDownload(taskID) {
    if (this.retries.has(taskID)) return this.retries.get(taskID);
    let task;
    try {task=this._task(taskID);} catch(error) {return Promise.reject(error);}
    if (!task.receipt || !['download_failed','failed','interrupted'].includes(task.status)) return Promise.reject(new Error('此任务没有可单独重试的下载。'));
    if (this.isBusy) throw new Error('已有生成或下载任务正在执行，请稍候。');
    this.active++;
    const promise=Promise.resolve().then(async()=>{
      this._checkDirectory(task.outputDirectory,task.directory);
      this._patch(taskID,{status:'downloading',error:null});
      await this._finishDownload(this._task(taskID));
      return this._task(taskID);
    }).finally(()=>{this.active--;this.retries.delete(taskID);this._emit();});
    this.retries.set(taskID,promise); this._emit(); return promise;
  }
  async _finishDownload(task) {
    try {
      this._checkDirectory(task.outputDirectory,task.directory);
      const bytes=await this.provider.download(clone(task.receipt));
      this._patch(task.id,{status:'validating'});
      let metadata=validateAudio(bytes,task.snapshot.params,task.snapshot.draft.mode);
      if (task.snapshot.params.format==='mp3') {
        if (typeof this.decodeAudio!=='function') throw new Error('MP3 解码器不可用');
        const decoded=await this.decodeAudio({data:Buffer.from(bytes),params:clone(task.snapshot.params),mode:task.snapshot.draft.mode});
        const maxDuration=task.snapshot.draft.mode==='podcast'?240:120;
        if (!Number.isFinite(decoded?.duration) || decoded.duration<=0 || decoded.duration>maxDuration) throw new Error('MP3 解码时长无效');
        metadata={duration:decoded.duration,durationVerified:true,validation:'已解码验证 MP3 与时长'};
      }
      this._checkDirectory(task.outputDirectory,task.directory);
      const outputPath=path.join(task.directory,`audio.${task.snapshot.params.format}`);
      writeAtomic(outputPath,bytes);
      let playbackPath=outputPath;
      if (task.snapshot.params.format==='pcm') {playbackPath=path.join(task.directory,'playback.wav');writeAtomic(playbackPath,audio.wrapPCM(bytes,task.snapshot.params));}
      writeAtomic(path.join(task.directory,'prompt.txt'),task.snapshot.prompt);
      writeAtomic(path.join(task.directory,'report.json'),JSON.stringify({version:1,model:'qwen-audio-3.1-tts-next',taskID:task.id,requestHash:task.requestHash,mode:task.mode,seed:task.seed,params:task.snapshot.params,bytes:bytes.length,sha256:digest(bytes),...metadata},null,2));
      this._patch(task.id,{status:'success',outputPath,playbackPath,bytes:bytes.length,...metadata,error:null});
    } catch { this._patch(task.id,{status:'download_failed',error:'音频下载、验证或保存失败，可单独重试下载；不会重新生成。'}); }
  }
  _checkDirectory(outputDirectory,directory) {
    if (!outputDirectory || fs.realpathSync(outputDirectory)!==outputDirectory || !fs.statSync(outputDirectory).isDirectory()) throw new Error('已确认的输出目录已变化或不可用。');
    fs.accessSync(outputDirectory,fs.constants.W_OK);
    if (directory && (!under(outputDirectory,directory) || fs.realpathSync(directory)!==directory || !fs.statSync(directory).isDirectory())) throw new Error('任务输出目录已变化或不可用。');
  }
  _task(id) {const task=this.store.snapshot().tasks.find(item=>item.id===id);if(!task)throw new Error('任务不存在。');return task;}
  _patch(id,changes) {
    this.store.update(data=>{const task=data.tasks.find(item=>item.id===id);if(!task)throw new Error('任务不存在。');Object.assign(task,changes,{updatedAt:new Date(this.now()).toISOString()});});
    this._emit();
  }
  _emit() {try {this.onChange();}catch { /* UI notification cannot authorize or repeat a provider request. */ }}
}
module.exports={GenerationService};
