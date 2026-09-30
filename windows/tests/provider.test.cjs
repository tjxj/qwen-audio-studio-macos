'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const { synthesize, download, ProviderError, validWorkspaceID }=require('../src/core/provider.cjs');
const validReceipt=()=>({request_id:'req-123_ok',output:{audio:{url:'https://audio.example.test/file.wav?private=secret',expires_at:Date.now()/1000+3600}}});
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json'}});

test('synthesis sends exactly one paid POST to the validated workspace with redirects disabled',async()=>{
  let calls=0;
  const result=await synthesize({workspaceID:'workspace-123',apiKey:'secret-key',body:{model:'test',input:{}},fetchImpl:async(url,init)=>{
    calls++; assert.equal(url,'https://workspace-123.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer');
    assert.equal(init.method,'POST'); assert.equal(init.redirect,'error'); assert.equal(init.headers.Authorization,'Bearer secret-key'); assert.deepEqual(JSON.parse(init.body),{model:'test',input:{}});
    assert.ok(init.signal); return json(validReceipt());
  }});
  assert.equal(calls,1); assert.equal(result.requestID,'req-123_ok'); assert.match(result.audioURL,/^https:/);
});

test('invalid workspace labels and credentials are rejected before transport',async()=>{
  for(const label of ['','a.b','a/b','a?','-bad','bad-','含字','a'.repeat(64),'a\n']){
    assert.equal(validWorkspaceID(label),false,label);
    await assert.rejects(synthesize({workspaceID:label,apiKey:'key',body:{},fetchImpl:()=>assert.fail('network must not start')}));
  }
  assert.equal(validWorkspaceID('a'),true);
  for(const apiKey of ['','bad\r\nkey']) await assert.rejects(synthesize({workspaceID:'test',apiKey,body:{},fetchImpl:()=>assert.fail('network must not start')}));
});

test('unknown HTTP and network errors are redacted, uncertain, and never retried',async()=>{
  for (const fetchImpl of [async()=>json({message:'secret-key private=secret'},503),async()=>{throw new Error('secret-key private=secret');}]){
    let count=0; await assert.rejects(synthesize({workspaceID:'test',apiKey:'secret-key',body:{},fetchImpl:async(...args)=>{count++;return fetchImpl(...args);}}),err=>{
      assert.ok(err instanceof ProviderError); assert.equal(err.uncertain,true); assert.doesNotMatch(err.message,/secret-key|private=secret/); return true;
    }); assert.equal(count,1);
  }
});

test('synthesis rejects redirects, malformed IDs, insecure URLs, credentials in URLs, expired receipts and giant responses',async()=>{
  const variants=[{...validReceipt(),request_id:'bad/request'}, {...validReceipt(),request_id:''}, ...['http://example.test/audio','https://user:password@example.test/audio'].map(url=>({request_id:'ok',output:{audio:{url,expires_at:Date.now()/1000+30}}})),{request_id:'ok',output:{audio:{url:'https://example.test/audio',expires_at:1}}}];
  for(const data of variants) await assert.rejects(synthesize({workspaceID:'test',apiKey:'key',body:{},fetchImpl:async()=>json(data)}), /响应|response/i);
  await assert.rejects(synthesize({workspaceID:'test',apiKey:'key',body:{},fetchImpl:async()=>new Response('',{status:302,headers:{location:'https://evil.test/'}})}));
  await assert.rejects(synthesize({workspaceID:'test',apiKey:'key',body:{},fetchImpl:async()=>new Response('x'.repeat(1024*1024+1))}));
});

test('synthesis timeout is bounded even when a fake transport ignores its AbortSignal',async()=>{
  const start=Date.now(); let count=0;
  await assert.rejects(synthesize({workspaceID:'test',apiKey:'key',body:{},timeoutMs:15,fetchImpl:()=>{count++; return new Promise(()=>{});}}),err=>err.uncertain===true);
  assert.equal(count,1); assert.ok(Date.now()-start<1000);
});

test('download is a credential-free HTTPS GET with redirect denial and size validation',async()=>{
  const result=await download({audioURL:'https://audio.example.test/signed?token=x',expiresAt:Date.now()/1000+60,fetchImpl:async(url,init)=>{
    assert.equal(init.method,'GET'); assert.equal(init.redirect,'error'); assert.equal(init.headers.Authorization,undefined); assert.equal(init.headers.Cookie,undefined); return new Response(Buffer.from('audio'));
  }}); assert.equal(result.toString(),'audio');
  for(const audioURL of ['http://example.test/audio','https://user:pass@example.test/audio']) await assert.rejects(download({audioURL,expiresAt:Date.now()/1000+60,fetchImpl:()=>assert.fail('must reject before network')}));
  await assert.rejects(download({audioURL:'https://example.test/audio',expiresAt:1,fetchImpl:()=>assert.fail('must reject expired')}));
  await assert.rejects(download({audioURL:'https://example.test/audio',expiresAt:Date.now()/1000+60,fetchImpl:async()=>new Response('',{headers:{'content-length':'104857601'}})}));
  await assert.rejects(download({audioURL:'https://example.test/audio',expiresAt:Date.now()/1000+60,fetchImpl:async()=>new Response('')}));
});
