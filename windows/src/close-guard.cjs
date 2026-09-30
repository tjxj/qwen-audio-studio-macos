'use strict';
function createCloseGuard({flush,isBusy,confirm,close,report}){let pending;return function requestClose(){if(pending)return pending;pending=(async()=>{try{await flush();if(isBusy()&&!await confirm())return;close();}catch(error){report(error);}finally{pending=null;}})();return pending;};}
module.exports={createCloseGuard};
