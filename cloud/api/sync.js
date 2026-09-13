import {put,get,list,head,BlobNotFoundError} from '@vercel/blob';
import {validID,partPath,manifestBody} from '../lib/service.js';
import {authenticate,accountPath,reserveUpload} from '../lib/accounts.js';
import {readJSON,updateJSON,HttpError} from '../lib/storage.js';
export function createSyncHandler(deps = {}) {
  const {authenticate:auth = authenticate, readJSON:read = readJSON, updateJSON:update = updateJSON, store = {put,get,list,head}} = deps;
  const {put:writeBlob,get:readBlob,list:listBlobs,head:headBlob} = store;
  return async function handler(req,res) {
  res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
  if(!process.env.BLOB_READ_WRITE_TOKEN&&!process.env.BLOB_STORE_ID)return res.status(503).json({error:'Sync is being configured. Please try again later.'});
  const {action,id,part,upload,cursor}=req.query;
  try {
    const context=await auth(req), prefix=context.prefix;
    const manifestPath=id=>`${prefix}manifests/${id}.json`;
    const chunkPath=(id,part,upload)=>prefix+partPath(id,part,upload);
    async function reservation(id,upload) {
      if(context.kind==='legacy')return null;
      const account=(await read(accountPath(context.id)))?.value;
      const item=account?.uploads[id];
      if(!item||item.upload!==upload||item.clearing||(!item.complete&&Date.now()-item.startedAt>3000000))throw new HttpError(409,'Start or retry the voice upload before sending parts.');
      return item;
    }
    if(req.method==='POST'&&action==='begin') {
      const manifest=manifestBody(req.body);
      try {
        await headBlob(manifestPath(manifest.id));
        if(context.kind!=='legacy')await update(accountPath(context.id),a=>({...a,uploads:{...a.uploads,[manifest.id]:{...a.uploads[manifest.id],complete:true}}}));
        return res.json({ok:true,complete:true});
      } catch(error) {if(!(error instanceof BlobNotFoundError))throw error;}
      if(context.kind!=='legacy')await update(accountPath(context.id),a=>reserveUpload(a,manifest));
      return res.json({ok:true,complete:false});
    }
    if(req.method==='GET'&&action==='list') {
      const result=await listBlobs({prefix:prefix+'manifests/',limit:100,cursor:typeof cursor==='string'?cursor:undefined});
      return res.json({voices:result.blobs.map(b=>({id:b.pathname.slice((prefix+'manifests/').length,-5),updatedAt:b.uploadedAt})),cursor:result.hasMore?result.cursor:null});
    }
    if(req.method==='GET'&&action==='manifest') {
      if(!validID(id))return res.status(400).json({error:'Invalid voice.'});
      const result=await readBlob(manifestPath(id),{access:'private',useCache:false});
      if(!result)return res.status(404).json({error:'Voice not found.'});
      return res.json(await new Response(result.stream).json());
    }
    if(req.method==='GET'&&action==='chunk') {
      const path=chunkPath(id,Number(part),upload),result=await readBlob(path,{access:'private',useCache:false});
      if(!result)return res.status(404).json({error:'Voice data is unavailable. Try syncing again.'});
      const data=Buffer.from(await new Response(result.stream).arrayBuffer());return res.json({data:data.toString('base64')});
    }
    if(req.method==='POST'&&action==='chunk') {
      const body=req.body,path=chunkPath(body?.id,body?.part,body?.upload);
      if(typeof body.data!=='string'||body.data.length>699052||!/^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body.data))return res.status(400).json({error:'Invalid encrypted data.'});
      const data=Buffer.from(body.data,'base64');if(!data.length||data.length>512*1024)return res.status(413).json({error:'Voice part is too large.'});
      const slot=await reservation(body.id,body.upload);
      if(slot&&(body.part>=slot.parts||data.length!==Math.min(512*1024,slot.bytes-body.part*512*1024)))throw new HttpError(400,'Voice part does not match its reserved size.');
      // Existing completed snapshots are immutable. A repeated sync is a no-op.
      try{await headBlob(manifestPath(body.id));return res.json({ok:true});}catch(error){if(!(error instanceof BlobNotFoundError))throw error;}
      await writeBlob(path,data,{access:'private',addRandomSuffix:false,allowOverwrite:true,contentType:'application/octet-stream',cacheControlMaxAge:60});return res.json({ok:true});
    }
    if(req.method==='POST'&&action==='commit') {
      const manifest=manifestBody(req.body);
      await reservation(manifest.id,manifest.upload);
      try{await headBlob(manifestPath(manifest.id));return res.json({ok:true});}catch(error){if(!(error instanceof BlobNotFoundError))throw error;}
      let size=0;
      for(let i=0;i<manifest.parts;i++)size+=(await headBlob(chunkPath(manifest.id,i,manifest.upload))).size;
      if(size!==manifest.bytes)return res.status(409).json({error:'The upload is incomplete. Try syncing again.'});
      await writeBlob(manifestPath(manifest.id),JSON.stringify(manifest),{access:'private',addRandomSuffix:false,allowOverwrite:true,contentType:'application/json',cacheControlMaxAge:60});
      if(context.kind!=='legacy')await update(accountPath(context.id),a=>({...a,uploads:{...a.uploads,[manifest.id]:{...a.uploads[manifest.id],complete:true}}}));
      return res.json({ok:true});
    }
    res.setHeader('Allow','GET, POST');return res.status(405).json({error:'Unsupported sync operation.'});
  }catch(error){if(error.status)return res.status(error.status).json({error:error.message});if(error instanceof BlobNotFoundError)return res.status(404).json({error:'Voice not found.'});if(/Invalid/.test(error.message))return res.status(400).json({error:error.message});return res.status(503).json({error:'Cloud storage is temporarily unavailable. Your local voices are safe.'});}
}

}
export default createSyncHandler();
