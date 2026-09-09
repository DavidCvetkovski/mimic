import {put,get,list,head,BlobNotFoundError} from '@vercel/blob';
import {authorised,validID,partPath,manifestBody} from '../lib/service.js';
export default async function handler(req,res) {
  res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
  if(!process.env.SYNC_AUTH_SHA256||(!process.env.BLOB_READ_WRITE_TOKEN&&!process.env.BLOB_STORE_ID))return res.status(503).json({error:'Sync is being configured. Please try again later.'});
  if(!authorised(req.headers.authorization,process.env.SYNC_AUTH_SHA256))return res.status(401).json({error:'That pairing key does not match this private library.'});
  const origin=req.headers.origin;
  if(origin&&!['https://mimic.lyricstats.dev','https://mimic-umber.vercel.app',process.env.VERCEL_URL&&'https://'+process.env.VERCEL_URL].includes(origin))return res.status(403).json({error:'Use the Mimic sync website.'});
  const {action,id,part,upload,cursor}=req.query;
  try {
    if(req.method==='GET'&&action==='list') {
      const result=await list({prefix:'manifests/',limit:100,cursor:typeof cursor==='string'?cursor:undefined});
      return res.json({voices:result.blobs.map(b=>({id:b.pathname.slice(10,-5),updatedAt:b.uploadedAt})),cursor:result.hasMore?result.cursor:null});
    }
    if(req.method==='GET'&&action==='manifest') {
      if(!validID(id))return res.status(400).json({error:'Invalid voice.'});
      const result=await get(`manifests/${id}.json`,{access:'private',useCache:false});
      if(!result)return res.status(404).json({error:'Voice not found.'});
      return res.json(await new Response(result.stream).json());
    }
    if(req.method==='GET'&&action==='chunk') {
      const path=partPath(id,Number(part),upload),result=await get(path,{access:'private',useCache:false});
      if(!result)return res.status(404).json({error:'Voice data is unavailable. Try syncing again.'});
      const data=Buffer.from(await new Response(result.stream).arrayBuffer());return res.json({data:data.toString('base64')});
    }
    if(req.method==='POST'&&action==='chunk') {
      const body=req.body,path=partPath(body?.id,body?.part,body?.upload);
      if(typeof body.data!=='string'||body.data.length>699052||!/^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body.data))return res.status(400).json({error:'Invalid encrypted data.'});
      const data=Buffer.from(body.data,'base64');if(!data.length||data.length>512*1024)return res.status(413).json({error:'Voice part is too large.'});
      // Existing completed snapshots are immutable. A repeated sync is a no-op.
      try{await head(`manifests/${body.id}.json`);return res.json({ok:true});}catch(error){if(!(error instanceof BlobNotFoundError))throw error;}
      await put(path,data,{access:'private',addRandomSuffix:false,allowOverwrite:true,contentType:'application/octet-stream',cacheControlMaxAge:60});return res.json({ok:true});
    }
    if(req.method==='POST'&&action==='commit') {
      const manifest=manifestBody(req.body);
      try{await head(`manifests/${manifest.id}.json`);return res.json({ok:true});}catch(error){if(!(error instanceof BlobNotFoundError))throw error;}
      let size=0;
      for(let i=0;i<manifest.parts;i++)size+=(await head(partPath(manifest.id,i,manifest.upload))).size;
      if(size!==manifest.bytes)return res.status(409).json({error:'The upload is incomplete. Try syncing again.'});
      await put(`manifests/${manifest.id}.json`,JSON.stringify(manifest),{access:'private',addRandomSuffix:false,allowOverwrite:true,contentType:'application/json',cacheControlMaxAge:60});return res.json({ok:true});
    }
    res.setHeader('Allow','GET, POST');return res.status(405).json({error:'Unsupported sync operation.'});
  }catch(error){if(error instanceof BlobNotFoundError)return res.status(404).json({error:'Voice not found.'});if(/Invalid/.test(error.message))return res.status(400).json({error:error.message});return res.status(503).json({error:'Cloud storage is temporarily unavailable. Your local voices are safe.'});}
}
