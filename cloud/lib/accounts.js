import {createHash,randomBytes,timingSafeEqual} from 'node:crypto';
import {verifyToken} from '@clerk/backend';
import {authorised,validID} from './service.js';
import {readJSON,writeJSON,updateJSON,HttpError} from './storage.js';
export const digest = value => createHash('sha256').update(value).digest('hex');
export const accountPath = id => `accounts/${id}/account.json`;
export const devicePath = id => `devices/${id}.json`;
export const origins = () => ['https://mimic.lyricstats.dev','https://mimic-umber.vercel.app',
  ...(process.env.VERCEL_URL ? ['https://'+process.env.VERCEL_URL] : [])];
export function checkOrigin(req) {
  if(req.headers.origin && !origins().includes(req.headers.origin)) throw new HttpError(403,'Use the Mimic website.');
}
export function equalHash(a,b) {
  return validID(a)&&validID(b)&&timingSafeEqual(Buffer.from(a,'hex'),Buffer.from(b,'hex'));
}
export async function session(req) {
  const token=/^Bearer (\S+)$/.exec(req.headers.authorization||'')?.[1];
  if(!process.env.CLERK_SECRET_KEY)throw new HttpError(503,'Email sign-in is not configured yet. Existing pairing keys still work.');
  if(!token)throw new HttpError(401,'Sign in to your Mimic account.');
  let claims;
  try { claims=await verifyToken(token,{secretKey:process.env.CLERK_SECRET_KEY,authorizedParties:origins()}); }
  catch {throw new HttpError(401,'Your session expired. Please sign in again.');}
  if(!claims.sub || !claims.sid || !origins().includes(claims.azp))throw new HttpError(401,'Please sign in again.');
  return {id:digest(claims.sub),kind:'session'};
}
export function deviceCredentials(header) {
  const match=/^Device ([a-f0-9]{32})\.([a-f0-9]{64})$/.exec(header||'');
  if(!match)throw new HttpError(401,'This device is not paired. Connect it from the Mimic website.');
  return {id:match[1],hash:digest(Buffer.from(match[2],'hex'))};
}
export async function authenticate(req, {read=readJSON, verify=session} = {}) {
  checkOrigin(req);
  if(authorised(req.headers.authorization,process.env.SYNC_AUTH_SHA256))return {kind:'legacy',prefix:''};
  let identity;
  if((req.headers.authorization||'').startsWith('Device ')) {
    const proof=deviceCredentials(req.headers.authorization);
    const device=(await read(devicePath(proof.id)))?.value;
    if(!device || device.revoked || !equalHash(device.secretHash,proof.hash))throw new HttpError(401,'This device connection was removed. Pair it again on the website.');
    identity={id:device.accountId,kind:'device',deviceId:proof.id};
  } else identity=await verify(req);
  const account=(await read(accountPath(identity.id)))?.value;
  if(!account)throw new HttpError(409,'Create or recover your encrypted library on the Mimic website first.');
  if(identity.kind==='device'&&!account.devices.includes(identity.deviceId))throw new HttpError(401,'This device is no longer connected.');
  return {...identity,account,prefix:account.prefix};
}
export function newAccount(id, verifier) {
  if(!validID(id)||!validID(verifier))throw new HttpError(400,'Invalid library setup.');
  return {version:2,prefix:`vaults/${id}/`,verifier,createdAt:new Date().toISOString(),devices:[],uploads:{}};
}
export function reserveUpload(account,manifest) {
  const existing=account.uploads[manifest.id];
  if(existing) {
    if(existing.complete)return account;
    if(existing.upload!==manifest.upload)throw new HttpError(409,'An earlier upload of this voice is incomplete. Unfinished uploads can be cleared after one hour in Account.');
    if(existing.bytes!==manifest.bytes||existing.parts!==manifest.parts)throw new HttpError(409,'Upload size changed.');
    return account;
  }
  const uploads=Object.values(account.uploads);
  if(uploads.length>=100 || uploads.reduce((n,u)=>n+u.bytes,0)+manifest.bytes>256*1024*1024)
    throw new HttpError(413,'Your library limit is 100 voice snapshots or 256 MiB. Clear expired unfinished uploads to free space.');
  return {...account,uploads:{...account.uploads,[manifest.id]:{...manifest,complete:false,startedAt:Date.now()}}};
}
export async function enrollDevice(identity,name) {
  if(typeof name!=='string'||!name.trim()||name.trim().length>60)throw new HttpError(400,'Name this device using 1–60 characters.');
  const id=randomBytes(16).toString('hex'), secret=randomBytes(32).toString('hex');
  const device={id,accountId:identity.id,name:name.trim(),secretHash:digest(Buffer.from(secret,'hex')),createdAt:new Date().toISOString(),revoked:false};
  // Reserve a slot atomically before issuing a credential. Orphans cannot authenticate.
  await updateJSON(accountPath(identity.id), account=>{
    if(!account)throw new HttpError(409,'Create your library first.');
    if(account.devices.length>=16)throw new HttpError(409,'Disconnect an old device before adding another (16 device limit).');
    return {...account,devices:[...account.devices,id]};
  });
  try {await writeJSON(devicePath(id),device);}
  catch(error){await updateJSON(accountPath(identity.id),a=>({...a,devices:a.devices.filter(x=>x!==id)}));throw error;}
  return {id,secret,name:device.name};
}
