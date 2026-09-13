import {session,authenticate,checkOrigin,accountPath,devicePath,newAccount,equalHash,enrollDevice} from '../lib/accounts.js';
import {readJSON,updateJSON,blob,HttpError} from '../lib/storage.js';
import {validID} from '../lib/service.js';
export default async function handler(req,res) {
  res.setHeader('Cache-Control','no-store');
  try {
    checkOrigin(req);
    if(req.method==='GET' && req.query.action==='config')return res.json({publishableKey:process.env.CLERK_PUBLISHABLE_KEY||process.env.NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY||null});
    const identity=await session(req), path=accountPath(identity.id);
    const action=req.query.action;
    if(req.method==='GET' && action==='status') {
      const account=(await readJSON(path))?.value;
      if(!account)return res.json({exists:false});
      const devices=(await Promise.all(account.devices.map(id=>readJSON(devicePath(id)))))
        .filter(d=>d&&!d.value.revoked).map(({value:d})=>({id:d.id,name:d.name,createdAt:d.createdAt}));
      const uploads=Object.values(account.uploads);
      return res.json({exists:true,verifier:account.verifier,devices,bytes:uploads.reduce((n,u)=>n+u.bytes,0),
        snapshots:uploads.filter(u=>u.complete).length,pending:uploads.filter(u=>!u.complete&&Date.now()-u.startedAt>3600000).length});
    }
    if(req.method==='POST' && action==='create') {
      const verifier=req.body?.verifier;
      if(!validID(verifier))throw new HttpError(400,'Invalid recovery key verification.');
      await updateJSON(path,existing=>{
        if(existing) {if(!equalHash(existing.verifier,verifier))throw new HttpError(409,'This account already has a library. Unlock it with its recovery key.');return existing;}
        return newAccount(identity.id,verifier);
      });
      return res.json({ok:true});
    }
    if(req.method==='POST' && action==='pair') {
      const account=(await readJSON(path))?.value;
      if(!account||!equalHash(account.verifier,req.body?.verifier))throw new HttpError(403,'Unlock your library with its recovery key first.');
      return res.json(await enrollDevice(identity,req.body?.name));
    }
    if(req.method==='POST' && action==='revoke') {
      const id=req.body?.id;
      if(typeof id!=='string'||!/^[a-f0-9]{32}$/.test(id))throw new HttpError(400,'Invalid device.');
      await updateJSON(devicePath(id),device=>{
        if(!device||device.accountId!==identity.id)throw new HttpError(404,'Device not found.');
        return {...device,revoked:true};
      });
      await updateJSON(path,a=>({...a,devices:a.devices.filter(x=>x!==id)}));
      return res.json({ok:true});
    }
    if(req.method==='POST' && action==='clear-pending') {
      const context=await authenticate(req);
      // Hold reservations until all their data has been removed; uploads check
      // this state before writing. A later retry uses a different upload ID.
      const account=await updateJSON(path,a=>({...a,uploads:Object.fromEntries(Object.entries(a.uploads).map(([id,u])=>[id,u.complete||Date.now()-u.startedAt<=3600000?u:{...u,clearing:true}]))}));
      for(const [id,u] of Object.entries(account.uploads).filter(([,u])=>u.clearing)) {
        const result=await blob.list({prefix:`${context.prefix}voices/${id}/${u.upload}/`,limit:100});
        if(result.blobs.length)await blob.del(result.blobs.map(b=>b.url));
        await updateJSON(path,a=>{const uploads={...a.uploads};if(uploads[id]?.upload===u.upload&&uploads[id].clearing)delete uploads[id];return {...a,uploads};});
      }
      return res.json({ok:true});
    }
    throw new HttpError(405,'Unsupported account operation.');
  } catch(error) {res.status(error.status||503).json({error:error.status?error.message:'Account storage is temporarily unavailable. Please retry.'});}
}
