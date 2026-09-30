'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const names=['bootstrap','saveDraft','saveSettings','chooseOutputDirectory','preflight','cancelPreflight','submit','retryDownload','pickReference','saveReference','removeReference','readAudio','updateTask','revealTask','exportTask','chat','clearChat','expandTemplate','saveTemplate','removeTemplate','favoriteTemplate'];
const bridge=Object.fromEntries(names.map(name=>[name,async value=>{const response=await ipcRenderer.invoke('studio:invoke',name,value);if(!response||!response.ok)throw new Error(response?.error||'操作未完成。');return response.value;}]));
bridge.onState=callback=>{if(typeof callback!=='function')throw new Error('无效的事件处理器。');const listener=(_event,state)=>callback(state);ipcRenderer.on('studio:state',listener);return ()=>ipcRenderer.removeListener('studio:state',listener);};
bridge.onBeforeClose=callback=>{if(typeof callback!=='function')throw new Error('无效的保存处理器。');const listener=async(_event,id)=>{try{await callback();ipcRenderer.send('studio:close-ready',{id,ok:true});}catch{ipcRenderer.send('studio:close-ready',{id,ok:false});}};ipcRenderer.on('studio:before-close',listener);return ()=>ipcRenderer.removeListener('studio:before-close',listener);};
contextBridge.exposeInMainWorld('studio',Object.freeze(bridge));
