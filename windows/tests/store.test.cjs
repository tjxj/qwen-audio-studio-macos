'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Store } = require('../src/core/store.cjs');
const temp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'qwen-store-'));

test('store persists atomically and snapshots cannot mutate live records', t => {
  const dir = temp(); t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const store = new Store(dir);
  const initial = store.load();
  assert.equal(initial.version, 1);
  assert.equal(initial.draft.params.format, 'wav');
  initial.draft.name = 'not persisted';
  assert.notEqual(store.snapshot().draft.name, 'not persisted');
  store.update(data => { data.draft.name = '作品'; data.tasks.push({id:'complete',status:'success'}); });
  assert.equal(new Store(dir).load().draft.name, '作品');
  assert.equal(fs.readdirSync(dir).filter(name => name.endsWith('.tmp')).length, 0);
});

test('failed mutation and failed disk commit preserve previous live data', t => {
  const dir = temp(); t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const store = new Store(dir); store.load();
  assert.throws(() => store.update(data => {data.draft.name='bad'; throw new Error('stop');}));
  assert.notEqual(store.snapshot().draft.name, 'bad');
  const original = fs.renameSync; fs.renameSync = () => { throw new Error('disk unavailable'); };
  try { assert.throws(() => store.update(data => { data.draft.name='lost'; }), /disk unavailable/); }
  finally { fs.renameSync = original; }
  assert.notEqual(store.snapshot().draft.name, 'lost');
  assert.notEqual(new Store(dir).load().draft.name, 'lost');
});

test('restart marks every nonterminal job interrupted without replaying', t => {
  const dir=temp(); t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const store=new Store(dir); store.load();
  store.update(data=> { data.tasks=['preparing','requesting','downloading','validating','success','uncertain','download_failed','failed'].map((status,id)=>({id:String(id),status})); });
  const recovered=new Store(dir).load();
  assert.deepEqual(recovered.tasks.map(t=>t.status),['interrupted','uncertain','interrupted','interrupted','success','uncertain','download_failed','failed']);
  assert.equal(new Store(dir).load().tasks[0].status,'interrupted');
});

test('corrupt or incompatible database fails closed instead of discarding history', t => {
  const dir=temp(); t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const store=new Store(dir); store.load();
  const file=path.join(dir,'studio.json');
  fs.writeFileSync(file,'{"version":99}');
  assert.throws(()=>new Store(dir).load(), /version|版本|schema/i);
  fs.writeFileSync(file,'broken');
  assert.throws(()=>new Store(dir).load());
  assert.equal(fs.readFileSync(file,'utf8'),'broken');
});

test('a best-effort directory-close error after rename cannot report an uncommitted update',t=>{
  const dir=temp();t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));const store=new Store(dir);store.load();
  const close=fs.closeSync;
  fs.closeSync=fd=>{const directory=fs.fstatSync(fd).isDirectory();close(fd);if(directory)throw new Error('directory close unsupported');};
  try {assert.doesNotThrow(()=>store.update(data=>{data.draft.name='committed';}));} finally {fs.closeSync=close;}
  assert.equal(store.snapshot().draft.name,'committed');assert.equal(new Store(dir).load().draft.name,'committed');
});
