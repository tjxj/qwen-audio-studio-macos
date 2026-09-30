'use strict';
const {BrowserWindow,ipcMain}=require('electron');const path=require('node:path');const {randomUUID}=require('node:crypto');
/** Decode with the exact bundled Chromium media stack, isolated from the app UI and credentials. */
async function decodeAudio({data,params}){
  if(!Buffer.isBuffer(data)||data.length===0||data.length>100*1024*1024)throw new Error('解码音频大小无效。');
  const channel=`studio:decoded:${randomUUID()}`;
  const decoder=new BrowserWindow({width:64,height:64,show:false,webPreferences:{preload:path.join(__dirname,'decoder-preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,webSecurity:true,spellcheck:false}});
  decoder.webContents.setWindowOpenHandler(()=>({action:'deny'}));decoder.webContents.on('will-navigate',event=>event.preventDefault());
  return new Promise((resolve,reject)=>{let settled=false;const timer=setTimeout(()=>finish(new Error('音频解码超时。')),20000);
    function finish(error,value){if(settled)return;settled=true;clearTimeout(timer);ipcMain.removeListener(channel,listener);if(!decoder.isDestroyed())decoder.destroy();if(error)reject(error);else resolve(value);}
    function listener(event,result){if(event.sender!==decoder.webContents||event.senderFrame!==decoder.webContents.mainFrame)return;if(!result||result.error||!Number.isFinite(result.duration)||result.duration<=0)return finish(new Error('音频无法完整解码。'));finish(null,{duration:result.duration});}
    ipcMain.on(channel,listener);decoder.once('closed',()=>finish(new Error('音频解码窗口已关闭。')));
    decoder.loadFile(path.join(__dirname,'decoder.html')).then(()=>{if(!settled)decoder.webContents.send('studio:decode',{channel,data:new Uint8Array(data),sampleRate:params.sampleRate,channels:params.channels});}).catch(()=>finish(new Error('无法加载安全音频解码器。')));
  });
}
module.exports={decodeAudio};
