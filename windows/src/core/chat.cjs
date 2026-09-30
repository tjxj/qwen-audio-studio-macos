'use strict';
function chatEndpoint(value) {
  let url;
  try { url=new URL(value); } catch { throw new Error('AI 编剧接口地址无效。'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error('AI 编剧地址必须为不含凭据、查询参数或片段的 HTTPS URL。');
  url.pathname=url.pathname.replace(/\/+$/,'');
  if (!url.pathname.endsWith('/chat/completions')) url.pathname+='/chat/completions';
  return url.href;
}
const SYSTEM_PROMPT = `你是 Qwen Audio Studio 的专业音频剧本编剧。为 qwen-audio-3.1-tts-next 编写包含人物对白、环境音、动作音效与配乐的完整全景声音频提示词。支持播客、广告、有声书、广播剧、游戏配音、旁白、自定义。保持角色音色一致、对白自然，注明情绪、停顿、声音空间与建议时长。正文必须少于 2800 Unicode 字符。只有用户明确使用参考音频时才使用 @voice1 到 @voice3。最终剧本用以下格式输出：\n\`\`\`qwen-script\n[标题]: 简短标题\n[模式]: 播客\n完整剧本\n\`\`\``;
async function requestChat({baseURL,apiKey,model,messages,fetchImpl=fetch}) {
  const endpoint=chatEndpoint(baseURL);
  if(typeof apiKey!=='string'||!apiKey.trim()||/[\r\n]/.test(apiKey))throw new Error('请先配置 AI 编剧 API Key。');
  if(typeof model!=='string'||!model.trim()||model.length>200)throw new Error('请填写有效的模型名称。');
  if(!Array.isArray(messages)||messages.some(m=>!['user','assistant'].includes(m.role)||typeof m.content!=='string'||m.content.length>20000))throw new Error('对话内容无效或过长。');
  let response;
  try {response=await fetchImpl(endpoint,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${apiKey}`},body:JSON.stringify({model:model.trim(),temperature:0.7,messages:[{role:'system',content:SYSTEM_PROMPT},...messages.slice(-10).map(({role,content})=>({role,content}))]}),redirect:'error',signal:AbortSignal.timeout(90000)});}catch{throw new Error('AI 编剧连接未完成，请检查网络；不会自动重试。');}
  if(!response.ok)throw new Error(`AI 编剧返回 HTTP ${response.status}。请检查接口、模型与凭据。`);
  const length=Number(response.headers.get('content-length'));
  if(length>2*1024*1024)throw new Error('AI 编剧响应过大。');
  let text='';const reader=response.body?.getReader();
  if(!reader)throw new Error('AI 编剧返回空响应。');
  const chunks=[];let size=0;
  try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>2*1024*1024){await reader.cancel();throw new Error();}chunks.push(value);}text=Buffer.concat(chunks).toString('utf8');}catch{throw new Error('AI 编剧响应无效或过大。');}
  let content;try{content=JSON.parse(text).choices?.[0]?.message?.content;}catch{}
  if(typeof content!=='string'||!content.trim()||content.length>20000)throw new Error('AI 编剧返回的数据格式不符合预期。');
  return content;
}
module.exports={chatEndpoint,requestChat};
