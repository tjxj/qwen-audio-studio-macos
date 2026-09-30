'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { MODES, DEFAULT_PARAMS, compilePrompt, validateParams, makeRequest, candidateSeeds, expandTemplate, parseScript } = require('../src/core/domain.cjs');
const { encodeWav, wrapPCM } = require('../src/core/audio.cjs');
const params = changes => ({ ...DEFAULT_PARAMS, ...changes });
const binding = (referenceID = 'voice-a', slot = 1) => ({ referenceID, slot, alias: '角色' });
const reference = (changes = {}) => ({ id: 'voice-a', slot: 1, name: 'voice.wav', duration: 1, mimeType: 'audio/wav', data: encodeWav({ samples: new Float32Array(24000), sampleRate: 24000 }), ...changes });
const template = (changes = {}) => ({ id: 'custom-test', source: 'user', version: 1, name: '测试', mode: 'auto', description: '', tags: [], role_count: 1, prompt_pattern: '{{x}}', variables: [{ key: 'x', label: '文字', type: 'text', required: true, default: '正文' }], ...changes });

test('all seven mode identities, titles and generation defaults match Swift', () => {
  assert.deepEqual(MODES, [{id:'podcast',title:'播客'}, {id:'advertisement',title:'广告'}, {id:'audiobook',title:'有声书'}, {id:'drama',title:'广播剧'}, {id:'game',title:'游戏配音'}, {id:'narration',title:'旁白'}, {id:'auto',title:'自定义'}]);
  assert.deepEqual(DEFAULT_PARAMS, {format:'wav', sampleRate:48000, channels:2, volume:50, rate:1, seed:42, enableCBR:false, bitRate:128, quality:5, enableAIGCTag:false});
  assert.ok(Object.isFrozen(DEFAULT_PARAMS)); assert.ok(Object.isFrozen(MODES));
});
test('compiles exact Swift guidance and preserves internal source whitespace for each mode', () => {
  const guidance = ['创作一段自然播客，保持说话人一致、声场连续和真实对话节奏。','创作一段商业广告音频，人声清晰，音效和配乐服务于信息表达。','创作一段广播剧，保持角色音色一致，按剧情顺序安排台词、环境和动作音效。','创作一段广播剧，保持角色音色一致，按剧情顺序安排台词、环境和动作音效。','创作一段广播剧，保持角色音色一致，按剧情顺序安排台词、环境和动作音效。','创作一段以清晰人声为核心的叙事音频。','根据以下要求创作完整音频。'];
  MODES.forEach(({id}, index) => {
    const result = compilePrompt({mode:id,prompt:'  台词  保留\n标点！  ',bindings:[]});
    assert.equal(result.text, guidance[index] + '\n内容与台词：\n台词  保留\n标点！');
    assert.equal(result.scalarCount, Array.from(result.text).length);
  });
});
test('counts Unicode code points including wrapper at exactly 3000, not UTF-16 units or graphemes', () => {
  const overhead = compilePrompt({ mode:'auto', prompt:'字', bindings:[] }).scalarCount - 1;
  const source = '🎵'.repeat(3000 - overhead);
  assert.equal(compilePrompt({ mode:'auto', prompt:source }).scalarCount, 3000);
  assert.throws(() => compilePrompt({ mode:'auto', prompt:source + '\u0301' }), /3000/);
  assert.throws(() => compilePrompt({ mode:'auto', prompt:'\ud800' }));
});
test('rejects empty source, invalid mode and wrong input types', () => {
  for (const prompt of ['', ' \n\t', null, 17, {}]) assert.throws(() => compilePrompt({mode:'auto',prompt}));
  for (const mode of ['unknown', 'toString', '', null]) assert.throws(() => compilePrompt({mode,prompt:'正文'}));
  assert.throws(() => compilePrompt({mode:'auto',prompt:'正文',bindings:{}}));
});
test('stable slots sort independently from array ordering and copy caller-owned bindings', () => {
  const a = binding(), b = binding('voice-b', 2); const bindings = [b, a];
  const result = compilePrompt({mode:'drama',prompt:'@voice2 你好',bindings});
  assert.deepEqual(result.bindings, [a, b]); assert.deepEqual(bindings, [b, a]);
  assert.ok(result.text.endsWith('参考音色：按 @voice1 到 @voice2 的编号使用参考音频。'));
  a.referenceID = 'mutated'; assert.equal(result.bindings[0].referenceID, 'voice-a');
});
test('rejects gaps, duplicate IDs, duplicate slots, invalid identifiers and more than three voices', () => {
  for (const bindings of [[binding('b',2)], [binding(),binding('b',3)], [binding(),binding('b',1)], [binding(),binding('voice-a',2)], [binding('',1)], [binding(null,1)], [binding('a','1')], [binding(),binding('b',2),binding('c',3),binding('d',4)], [null]]) assert.throws(() => compilePrompt({mode:'drama',prompt:'正文',bindings}));
});
test('invalid and absent voice markers are rejected without renumbering', () => {
  for (const prompt of ['@voice', '@voice0', '@voice4', '@voice01', '@voice12', '@voiceXYZ']) assert.throws(() => compilePrompt({mode:'drama',prompt,bindings:[binding()]}));
  for (const prompt of ['@voice1', '@voice2', '@voice3']) assert.throws(() => compilePrompt({mode:'drama',prompt,bindings:[]}));
  assert.doesNotThrow(() => compilePrompt({mode:'drama',prompt:'@voice1你好',bindings:[binding()]}));
});
test('validates parameter types and all numeric bounds without coercing strings or booleans', () => {
  assert.deepEqual(validateParams(DEFAULT_PARAMS), DEFAULT_PARAMS);
  const invalid = {format:['aac','WAV',0],sampleRate:[0,22050,48000.5,'48000'],channels:[0,3,1.5,'2'],volume:[-1,101,1.5,'50'],rate:[0.49,2.01,NaN,Infinity,'1'],seed:[-1,1.5,NaN,Number.MAX_SAFE_INTEGER+1,'42'],enableCBR:[0,'false',null],bitRate:[0,321,1.5,'128'],quality:[-1,10,1.5,'5'],enableAIGCTag:[1,'false',null]};
  for (const [key, values] of Object.entries(invalid)) for (const value of values) assert.throws(() => validateParams(params({[key]:value})), undefined, `${key}=${value}`);
  for (const key of Object.keys(DEFAULT_PARAMS)) { const missing = params(); delete missing[key]; assert.throws(() => validateParams(missing)); }
  for (const value of [null, [], 'params']) assert.throws(() => validateParams(value));
});
test('accepts inclusive parameter endpoints and supported sample rates', () => {
  for (const sampleRate of [8000,16000,24000,44100,48000]) for (const format of ['wav','mp3','pcm']) assert.doesNotThrow(() => validateParams(params({sampleRate,format})));
  assert.doesNotThrow(() => validateParams(params({volume:0,rate:0.5,quality:0,seed:0,channels:1,bitRate:8})));
  assert.doesNotThrow(() => validateParams(params({volume:100,rate:2,quality:9,seed:Number.MAX_SAFE_INTEGER,channels:2,bitRate:320})));
});
test('enforces every exact Swift MP3 constant-bitrate sample-rate band', () => {
  const bands = {8000:[8,16,24,32,40,48,56,64],16000:[8,16,24,32,40,48,56,64,80,96,112,128,144,160],24000:[8,16,24,32,40,48,56,64,80,96,112,128,144,160],44100:[32,40,48,56,64,80,96,112,128,160,192,224,256,320],48000:[32,40,48,56,64,80,96,112,128,160,192,224,256,320]};
  for (const [sampleRate, allowed] of Object.entries(bands)) for (let bitRate=8;bitRate<=320;bitRate++) {
    const run = () => validateParams(params({format:'mp3',enableCBR:true,sampleRate:Number(sampleRate),bitRate}));
    allowed.includes(bitRate) ? assert.doesNotThrow(run) : assert.throws(run);
  }
  assert.doesNotThrow(() => validateParams(params({format:'wav',enableCBR:true,sampleRate:8000,bitRate:128})));
  assert.doesNotThrow(() => validateParams(params({format:'mp3',enableCBR:false,sampleRate:8000,bitRate:128})));
});
test('serializes the exact Next wire contract and candidate seed override', () => {
  assert.deepEqual(makeRequest({prompt:'合成测试',params:params({format:'mp3',volume:61,rate:1.2,enableCBR:true,enableAIGCTag:true}),seed:17,references:[]}), {model:'qwen-audio-3.1-tts-next',input:{text_prompt:'合成测试',references:[],format:'mp3',sample_rate:48000,channels:2,volume:61,rate:1.2,seed:17,enable_cbr:true,bit_rate:128,quality:5,enable_aigc_tag:true}});
});
test('serializes references by stable slot and checks actual PCM bytes', () => {
  const a = reference(), b = reference({id:'voice-b',slot:2}); b.data.writeInt16LE(2,44);
  const result = makeRequest({prompt:'@voice2 你好',params:params(),seed:42,references:[b,a]});
  assert.deepEqual(result.input.references, [a,b].map(ref => ({audio_data:`data:audio/wav;base64,${ref.data.toString('base64')}`})));
  assert.equal(result.input.references[0].name, undefined);
});
test('rejects missing voices and malformed metadata before provider serialization', () => {
  for (const changes of [{id:''},{slot:2},{slot:'1'},{duration:0},{duration:31},{duration:NaN},{duration:'1'},{duration:0.8},{mimeType:'audio/mpeg'},{data:Buffer.from('bad')},{data:new Uint8Array(48)},{data:Buffer.alloc(10*1024*1024+1)}]) assert.throws(() => makeRequest({prompt:'正文',params:params(),seed:0,references:[reference(changes)]}));
  const data = wrapPCM(Buffer.alloc(24000*4),{sampleRate:24000,channels:2});
  assert.throws(() => makeRequest({prompt:'正文',params:params(),seed:0,references:[reference({data})]}));
  assert.throws(() => makeRequest({prompt:'@voice2',params:params(),seed:0,references:[reference()]}));
  assert.throws(() => makeRequest({prompt:'正文',params:params(),seed:0,references:[reference(),reference({slot:2})]}));
});
test('reference duration uses physical samples and includes exact thirty-second boundary', () => {
  const good = reference({duration:30,data:encodeWav({samples:new Float32Array(720000),sampleRate:24000})});
  assert.doesNotThrow(() => makeRequest({prompt:'正文',params:params(),seed:0,references:[good]}));
  const bad = reference({duration:30,data:encodeWav({samples:new Float32Array(720001),sampleRate:24000})});
  assert.throws(() => makeRequest({prompt:'正文',params:params(),seed:0,references:[bad]}));
});
test('request prompt is already compiled, well-formed, nonempty and at most 3000 code points', () => {
  assert.equal(makeRequest({prompt:'🎵'.repeat(3000),params:params(),seed:0,references:[]}).input.text_prompt.length,6000);
  for (const prompt of ['', '  ', null, 12, 'a'.repeat(3001), '\udfff']) assert.throws(() => makeRequest({prompt,params:params(),seed:0,references:[]}));
  for (const seed of [-1,1.5,'42',Infinity,Number.MAX_SAFE_INTEGER+1]) assert.throws(() => makeRequest({prompt:'正文',params:params(),seed,references:[]}));
});
test('candidate seeds are deterministic, unique and cannot overflow safe JSON integers', () => {
  assert.deepEqual(candidateSeeds(42,3),[42,43,44]); assert.deepEqual(candidateSeeds(0,1),[0]);
  assert.deepEqual(candidateSeeds(Number.MAX_SAFE_INTEGER-2,3),[Number.MAX_SAFE_INTEGER-2,Number.MAX_SAFE_INTEGER-1,Number.MAX_SAFE_INTEGER]);
  for (const [seed,count] of [[-1,1],[0,0],[0,4],[0,1.5],[0,'1'],['42',1],[1.2,1],[Number.MAX_SAFE_INTEGER,2],[NaN,1]]) assert.throws(() => candidateSeeds(seed,count));
});
test('all 42 unchanged built-in templates expand and compile for their seven modes', () => {
  const templates = JSON.parse(fs.readFileSync(path.join(__dirname,'../resources/templates.json'),'utf8'));
  assert.equal(templates.length,42); assert.equal(new Set(templates.map(item=>item.id)).size,42);
  for (const {id} of MODES) assert.equal(templates.filter(item=>item.mode===id).length,6);
  for (const item of templates) {
    const result = expandTemplate(item,{}); assert.equal(result.name,item.name); assert.equal(result.mode,item.mode); assert.ok(!result.prompt.includes('{{'));
    assert.ok(compilePrompt({...result,bindings:[]}).scalarCount<=3000);
  }
});
test('template text replacement is literal and code-point-aware', () => {
  assert.equal(expandTemplate(template(),{x:'$1\\literal🎵'}).prompt,'$1\\literal🎵');
  const item = template({variables:[{key:'x',label:'文字',type:'text',required:true,default:'正文',max_length:2}]});
  assert.equal(expandTemplate(item,{x:'🎵🎵'}).prompt,'🎵🎵');
  assert.throws(()=>expandTemplate(item,{x:'🎵🎵🎵'}));
});
test('template values reject unknown variables, wrong types, nested expressions and sensitive content', () => {
  for (const values of [{unknown:'x'},{x:1},{x:' '},{x:'{{other}}'},{x:'literal }}'},{x:'sk-'+ 'a'.repeat(24)},{x:'data:audio/wav;base64,AAAA'},{x:'llm-abcdefgh1234'},{x:'Authorization: Bearer hidden'},null,[]]) assert.throws(()=>expandTemplate(template(),values));
});
test('template number/select definitions enforce exact types, finite ranges and options', () => {
  const item = template({prompt_pattern:'{{count}} 次 {{style}}',variables:[{key:'count',label:'次数',type:'number',required:true,default:2,min:1,max:3},{key:'style',label:'风格',type:'select',required:true,default:'自然',options:['自然','轻快']}]});
  assert.equal(expandTemplate(item,{}).prompt,'2 次 自然');
  assert.equal(expandTemplate(item,{count:2.5,style:'轻快'}).prompt,'2.5 次 轻快');
  for (const values of [{count:0},{count:4},{count:Infinity},{count:'2'},{style:'未知'},{style:2}]) assert.throws(()=>expandTemplate(item,values));
});
test('invalid template definitions cannot hide undeclared placeholders or secrets in metadata', () => {
  for (const changes of [{id:''},{source:'remote'},{name:''},{name:'a'.repeat(81)},{mode:'bad'},{description:'a'.repeat(301)},{tags:Array(13).fill('x')},{tags:['a'.repeat(31)]},{role_count:4},{suggested_duration_seconds:601},{prompt_pattern:'{{unknown}}'},{prompt_pattern:'{{x + 1}}'},{prompt_pattern:'hello }}'},{prompt_pattern:'data:audio/wav;base64,AAAA'},{name:'sk-'+ 'a'.repeat(24)},{variables:[{key:'x',label:'x',type:'text',default:'{{x}}'}]},{variables:[{key:'x',label:'x',type:'text',default:'x',max_length:0}]},{variables:[{key:'x',label:'x',type:'number',default:2,min:3,max:1}]},{variables:[{key:'x',label:'x',type:'select',default:'a',options:[]}]},{variables:[{key:'x',label:'x',type:'text',default:'a'},{key:'x',label:'x',type:'text',default:'a'}]}]) assert.throws(()=>expandTemplate(template(changes),{}));
});
test('expanded templates enforce compiled length while retaining valid voice placeholders for later binding', () => {
  const item = template({prompt_pattern:'{{x}}{{x}}{{x}}',variables:[{key:'x',label:'x',type:'text',required:true,default:'短',max_length:1000}]});
  assert.throws(()=>expandTemplate(item,{x:'字'.repeat(1000)}),/3000/);
  assert.equal(expandTemplate(template({prompt_pattern:'@voice2 你好',variables:[]}),{}).prompt,'@voice2 你好');
  assert.throws(()=>expandTemplate(template({prompt_pattern:'@voice4 你好',variables:[]}),{}));
});
test('extracts latest nonempty qwen-script fence and removes Chinese metadata only', () => {
  const text='说明\n```qwen-script\n[标题]: 旧稿\n旧正文\n```\n思路\n```qwen-script\n[标题]：新稿\n[模式]：游戏配音\n  “你好”\n\n[audio] 开门\n```';
  assert.deepEqual(parseScript(text),{name:'新稿',mode:'game',prompt:'“你好”\n\n[audio] 开门'});
});
test('script import supports all Chinese modes, neutral fences and fallback defaults', () => {
  for (const {id,title} of MODES) assert.equal(parseScript('```qwen-script\n[模式]: '+title+'\n正文\n```').mode,id);
  assert.equal(parseScript('```\n[模式]: 解说\n正文\n```').mode,'narration');
  assert.deepEqual(parseScript('```\n正文\n```'),{name:'未命名灵感脚本',mode:'podcast',prompt:'正文'});
  assert.equal(parseScript('```\n[模式]: 未知\n正文\n```').mode,'auto');
});
test('script parsing returns null for absent, incomplete and metadata-only fences', () => {
  for (const text of ['',null,42,'正文','```qwen-script\n正文','```qwen-script\n[标题]: 空\n[模式]: 播客\n```']) assert.equal(parseScript(text),null);
  assert.equal(parseScript('```\n正文\n```\n```\n[标题]: 空\n```').prompt,'正文');
});

test('template numeric display preserves whole-number decimal formatting like Swift', () => {
  const item = template({variables:[{key:'x',label:'数字',type:'number',default:1e25}]});
  assert.equal(expandTemplate(item,{}).prompt,BigInt(1e25).toString());
  assert.equal(expandTemplate(item,{x:-0}).prompt,'-0');
});
