'use strict';
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');let failed=false;let checked=0;
function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory())walk(file);else if(/\.(cjs|js)$/.test(file)){const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8'});if(result.status!==0){failed=true;console.error(result.stderr);}checked++;}}}
walk(path.join(root,'src'));walk(path.join(root,'scripts'));walk(path.join(root,'tests'));
const templates=JSON.parse(fs.readFileSync(path.join(root,'resources/templates.json'),'utf8'));const original=JSON.parse(fs.readFileSync(path.join(root,'../Sources/StudioCore/Resources/templates.json'),'utf8'));
if(JSON.stringify(templates)!==JSON.stringify(original)||templates.length!==42){failed=true;console.error('Template catalog differs from macOS source or lacks 42 entries.');}
const lock=JSON.parse(fs.readFileSync(path.join(root,'package-lock.json'),'utf8'));const pkg=JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8'));if(JSON.stringify(lock.packages[''].devDependencies)!==JSON.stringify(pkg.devDependencies)){failed=true;console.error('Dependency lockfile mismatch.');}
console.log(`Syntax checked ${checked} files; verified 42 shared templates and dependency lock.`);process.exitCode=failed?1:0;
