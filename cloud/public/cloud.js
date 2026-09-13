import {credentials,call,upload,download,validateArchive,decryptLabel,generateRecoveryKey,recoveryVerifier,devicePairingCode} from './vault.js';
const $=s=>document.querySelector(s);
let keys=null,root=null,clerk=null,account=null,activeUser=null,generation=0,busy=false,controller=null;
function message(text){$('#message').textContent=text;$('#message').hidden=!text;}
function working(value){busy=value;for(const s of ['#connect-button','#upload','#refresh','#generate-key','#create-vault','#pair-device button','#clear-pending','#lock','#signout'])$(s).disabled=value;$('#create-vault').disabled=value||!$('#key-saved').checked;$('#email-signin').disabled=value||!clerk;$('#email-signup').disabled=value||!clerk;}
function lock(){generation++;controller?.abort();keys=null;root=null;for(const s of ['#key','#recovery','#new-key','#pair-code'])$(s).value='';$('#key-saved').checked=false;$('#new-key-panel').hidden=true;$('#pair-result').hidden=true;$('#vault').hidden=true;$('#signin').hidden=false;$('#library').replaceChildren();$('#device-panel').hidden=true;$('#unlock-library').hidden=!account?.exists;$('#connection').textContent='Encrypted sync';working(false);}
function saveFile(data,name,type='application/json'){const url=URL.createObjectURL(new Blob([data],{type})),link=document.createElement('a');link.href=url;link.download=name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);}
async function authorization(){const token=await clerk?.session?.getToken();if(!token)throw new Error('Sign in again to continue.');return 'Bearer '+token;}
async function accountCall(action,body){const response=await fetch('/api/account?action='+action,{method:body?'POST':'GET',headers:{Authorization:await authorization(),...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});const data=await response.json();if(!response.ok)throw new Error(data.error||'Please try again.');return data;}
async function accountStatus(){
 const run=generation;const next=await accountCall('status');if(run!==generation)return;account=next;
 $('#account-signin').hidden=true;$('#legacy').hidden=true;$('#account').hidden=false;$('#account-name').textContent=clerk.user.primaryEmailAddress?.emailAddress||'Signed in';
 $('#create-library').hidden=account.exists;$('#unlock-library').hidden=!account.exists||Boolean(keys);$('#device-panel').hidden=!keys||!account.exists;
 $('#usage').textContent=account.exists?`${account.snapshots} voice snapshots · ${(account.bytes/1048576).toFixed(1)} of 256 MiB reserved or stored`:'';
 $('#clear-pending').hidden=!account.pending;
 $('#devices').replaceChildren();for(const device of account.devices||[]){const row=document.createElement('div'),name=document.createElement('span'),button=document.createElement('button');name.textContent=device.name;button.textContent='Disconnect';button.className='text-button';button.onclick=()=>operate(async()=>{await accountCall('revoke',{id:device.id});$('#pair-code').value='';$('#pair-result').hidden=true;await accountStatus();message('Device disconnected. Copies already on it stay there.');});row.append(name,button);$('#devices').append(row);}
}
async function operate(action){if(busy)return;working(true);message('');const run=generation;try{await action();}catch(error){if(run===generation)message(error.message);}finally{if(run===generation)working(false);}}
async function showVault(next){keys=next;$('#signin').hidden=true;$('#vault').hidden=false;$('#unlock-library').hidden=true;$('#connection').textContent='Private library connected';if(clerk?.user)await accountStatus();await refresh();}
async function refresh(){if(!keys)return;const run=generation,current=keys;controller?.abort();controller=new AbortController();const options={signal:controller.signal};
 const found=[];let cursor=null;do{const data=await call(current,'list'+(cursor?'&cursor='+encodeURIComponent(cursor):''),options);if(run!==generation)return;found.push(...data.voices);if(found.length>10000)throw new Error('Library is too large to display.');cursor=data.cursor;}while(cursor);
 $('#library').replaceChildren();$('#count').textContent=found.length?`${found.length} encrypted ${found.length===1?'voice':'voices'}`:'Your library is ready for its first voice.';
 for(const entry of found){const article=document.createElement('article');article.className='library-row';const info=document.createElement('div');info.className='voice-info';const title=document.createElement('h2');title.textContent='Encrypted voice';
 try{const manifest=await call(current,'manifest&id='+entry.id,options);if(manifest.label)title.textContent=await decryptLabel(manifest.label,current);}catch(error){if(error.name==='AbortError')return;}
 if(run!==generation)return;const note=document.createElement('p');note.textContent=new Date(entry.updatedAt).toLocaleDateString();info.append(title,note);const button=document.createElement('button');button.className='secondary';button.textContent='Download voice';article.append(info,button);$('#library').append(article);
 button.onclick=()=>operate(async()=>{const archive=await download(entry.id,current,options);if(run!==generation)return;validateArchive(archive);saveFile(JSON.stringify(archive),archive.name.replace(/[^\p{L}\p{N} _-]/gu,'_')+'.mimicvoice');message('Voice decrypted on this browser. Import the file in Mimic.');});
 }
}
$('#connect').onsubmit=event=>{event.preventDefault();operate(async()=>{const run=generation,next=await credentials($('#key').value);await call(next,'list');if(run!==generation)return;$('#key').value='';await showVault(next);});};
$('#lock').onclick=()=>{lock();message('Library locked. Encryption keys have been cleared from this page.');};
$('#refresh').onclick=()=>operate(refresh);
$('#upload').onchange=()=>operate(async()=>{const file=$('#upload').files[0],current=keys,run=generation;if(!file||!current)return;if(file.size>32*1048576)throw new Error('Choose a voice smaller than 32 MiB.');const archive=validateArchive(JSON.parse(await file.text()));if(run!==generation)return;controller=new AbortController();message('Encrypting and uploading…');try{await upload(archive,current,{signal:controller.signal});if(run!==generation)return;await refresh();if(clerk?.user)await accountStatus();message(`“${archive.name}” is ready to sync.`);}finally{$('#upload').value='';}});
$('#generate-key').onclick=()=>{root=generateRecoveryKey();$('#new-key').value=root;$('#new-key-panel').hidden=false;$('#key-saved').checked=false;$('#create-vault').disabled=true;};
$('#save-key').onclick=()=>{if(root)saveFile('Mimic recovery key\n\n'+root+'\n\nSign in at https://mimic.lyricstats.dev and use this key to unlock your encrypted library. Keep it private.\n','Mimic Recovery Key.txt','text/plain');};
$('#key-saved').onchange=()=>{$('#create-vault').disabled=!$('#key-saved').checked;};
$('#create-vault').onclick=()=>operate(async()=>{const run=generation;if(!root||!$('#key-saved').checked)return;const next=await credentials(root);await accountCall('create',{verifier:await recoveryVerifier(next)});if(run!==generation)return;next.getAuthorization=authorization;$('#new-key').value='';$('#new-key-panel').hidden=true;await showVault(next);});
$('#unlock-library').onsubmit=event=>{event.preventDefault();operate(async()=>{const run=generation;const value=$('#recovery').value.trim(),next=await credentials(value);if(await recoveryVerifier(next)!==account.verifier)throw new Error('That recovery key belongs to a different library.');if(run!==generation)return;root=value;$('#recovery').value='';next.getAuthorization=authorization;await showVault(next);});};
$('#pair-device').onsubmit=event=>{event.preventDefault();operate(async()=>{const run=generation;if(!root||!keys)throw new Error('Unlock your account library first.');const device=await accountCall('pair',{name:$('#device-name').value,verifier:await recoveryVerifier(keys)});if(run!==generation)return;$('#pair-code').value=devicePairingCode(root,device);$('#pair-result').hidden=false;await accountStatus();});};
$('#copy-pair').onclick=()=>operate(async()=>{await navigator.clipboard.writeText($('#pair-code').value);message('Pairing code copied. Paste it in the device’s Mimic settings.');});
$('#hide-pair').onclick=()=>{$('#pair-code').value='';$('#pair-result').hidden=true;};
$('#clear-pending').onclick=()=>operate(async()=>{await accountCall('clear-pending',{});await accountStatus();message('Unfinished uploads cleared. You can retry them now.');});
$('#signout').onclick=async()=>{lock();account=null;$('#account').hidden=true;$('#legacy').hidden=false;$('#account-signin').hidden=false;try{await clerk.signOut();}catch(error){message(error.message);}};
window.addEventListener('pagehide',lock);
async function start(){
 try{
  const config=await (await fetch('/api/account?action=config')).json(),pk=config.publishableKey;
  if(!pk){$('#auth-status').textContent='Email accounts are being configured. Your original private library remains available below.';return;}
  const host=atob(pk.split('_').slice(2).join('_')).replace(/\$$/,'');
  if(!/^[a-z0-9.-]+$/.test(host)||(!host.endsWith('.clerk.accounts.dev')&&host!=='clerk.mimic.lyricstats.dev'))throw new Error('Unexpected authentication domain.');
  const script=document.createElement('script');script.src=`https://${host}/npm/@clerk/clerk-js@5/dist/clerk.browser.js`;script.crossOrigin='anonymous';script.dataset.clerkPublishableKey=pk;
  await new Promise((resolve,reject)=>{script.onload=resolve;script.onerror=()=>reject(new Error('Sign-in could not load. Refresh to retry.'));document.head.append(script);});
  clerk=window.Clerk;await clerk.load();$('#email-signin').disabled=false;$('#email-signup').disabled=false;$('#auth-status').textContent='Email sign-in is managed by Clerk. Your recovery key unlocks the encrypted voices.';
  $('#email-signin').onclick=()=>clerk.openSignIn({forceRedirectUrl:location.origin});$('#email-signup').onclick=()=>clerk.openSignUp({forceRedirectUrl:location.origin});
  clerk.addListener(({user})=>{if((user?.id||null)===activeUser)return;activeUser=user?.id||null;lock();account=null;if(user)accountStatus().catch(e=>message(e.message));else{$('#account').hidden=true;$('#legacy').hidden=false;$('#account-signin').hidden=false;}});
  if(clerk.user && activeUser!==clerk.user.id){activeUser=clerk.user.id;await accountStatus();}
 }catch(error){$('#auth-status').textContent=error.message;}
}
start();
