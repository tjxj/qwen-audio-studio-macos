const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../src/renderer');
const port=Number(process.env.UI_TEST_PORT || 4177);
http.createServer((req,res) => {
  const pathname=new URL(req.url,'http://localhost').pathname;
  res.setHeader('Cache-Control','no-store');
  if(pathname==='/preview/' || pathname==='/preview') {
    res.setHeader('Content-Type','text/html');
    const html=fs.readFileSync(path.join(__dirname,'ui-preview.html'),'utf8').replaceAll('../src/renderer/','/').replace('src="ui-preview-bridge.js"','src="/preview-bridge.js"');
    res.end(html);return;
  }
  if(pathname==='/preview-bridge.js') {
    res.setHeader('Content-Type','text/javascript');res.end(fs.readFileSync(path.join(__dirname,'ui-preview-bridge.js')));return;
  }
  const file = path.resolve(root, '.' + pathname.replace(/\/$/, '/index.html'));
  if (!file.startsWith(root + path.sep)) {res.writeHead(403).end(); return;}
  const type={'.js':'text/javascript','.css':'text/css','.html':'text/html'}[path.extname(file)] || 'application/octet-stream';
  res.setHeader('Content-Type', type);
  try {res.end(fs.readFileSync(file));} catch {res.writeHead(404).end('Not found');}
}).listen(port, '127.0.0.1',()=>process.stdout.write(`Renderer test server http://127.0.0.1:${port}/preview/\n`));
