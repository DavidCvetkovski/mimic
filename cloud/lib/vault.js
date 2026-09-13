export const CHUNK_BYTES = 512 * 1024;
export const MAX_BYTES = 32 * 1024 * 1024;
const utf8 = new TextEncoder();
export const hex = bytes => Array.from(new Uint8Array(bytes),v=>v.toString(16).padStart(2,'0')).join('');
export const unhex = text => {
  if (!/^[0-9a-f]{64}$/i.test(text)) throw new Error('Use the complete 64-character pairing key.');
  return Uint8Array.from(text.match(/../g),v=>parseInt(v,16));
};
export const base64 = bytes => {
  let result=''; for(let i=0;i<bytes.length;i+=8192) result+=String.fromCharCode(...bytes.subarray(i,i+8192));
  return btoa(result);
};
export const unbase64 = text => Uint8Array.from(atob(text),v=>v.charCodeAt(0));
export async function credentials(pairingKey) {
  const master=await crypto.subtle.importKey('raw',unhex(pairingKey.trim()),'HKDF',false,['deriveBits']);
  const derive=async purpose => new Uint8Array(await crypto.subtle.deriveBits({name:'HKDF',hash:'SHA-256',salt:utf8.encode('mimic.sync.v1'),info:utf8.encode(purpose)},master,256));
  return {encryption:await derive('encryption'),token:hex(await derive('authentication'))};
}
export function validateArchive(archive) {
  if(archive?.format!=='mimic.voice'||archive.version!==1||typeof archive.name!=='string'||!archive.name.trim()||archive.name.length>60||/[\x00-\x1f\x7f/\\:]/.test(archive.name)||archive.name.startsWith('.')||!archive.files?.['codes.npy']||!archive.files?.['meta.json']) throw new Error('Choose a valid .mimicvoice file exported by Mimic.');
  const limits={'meta.json':1024*1024,'codes.npy':4*1024*1024,'reference.wav':16*1024*1024};
  for(const [name,data] of Object.entries(archive.files)) if(!(name in limits)||typeof data!=='string'||data.length>Math.ceil(limits[name]/3)*4||!unbase64(data).length) throw new Error('The voice file contains invalid or oversized data.');
  const meta=JSON.parse(new TextDecoder().decode(unbase64(archive.files['meta.json'])));
  if(typeof meta.reference_text!=='string'||!meta.reference_text.trim()) throw new Error('The voice has no reference transcript.');
  return archive;
}
export async function fingerprint(archive) {
  validateArchive(archive);
  const meta=JSON.parse(new TextDecoder().decode(unbase64(archive.files['meta.json'])));
  const parts=[unbase64(archive.files['codes.npy']),utf8.encode(meta.reference_text),archive.files['reference.wav']?unbase64(archive.files['reference.wav']):new Uint8Array(),utf8.encode(archive.name)];
  const joined=new Uint8Array(parts.reduce((n,p)=>n+p.length,0)+3); let at=0;
  parts.forEach((p,i)=>{joined.set(p,at);at+=p.length;if(i<3)at++;});
  return new Uint8Array(await crypto.subtle.digest('SHA-256',joined));
}
export async function objectID(archive,keys) {
  const key=await crypto.subtle.importKey('raw',keys.encryption,{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return hex(await crypto.subtle.sign('HMAC',key,await fingerprint(archive)));
}
export async function seal(archive,keys) {
  validateArchive(archive); const plain=utf8.encode(JSON.stringify(archive));
  if(plain.length>MAX_BYTES)throw new Error('Voice files must be smaller than 32 MiB.');
  const nonce=crypto.getRandomValues(new Uint8Array(12));
  const key=await crypto.subtle.importKey('raw',keys.encryption,'AES-GCM',false,['encrypt']);
  const ciphertext=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:utf8.encode('mimic.voice.v1')},key,plain));
  const combined=new Uint8Array(12+ciphertext.length);combined.set(nonce);combined.set(ciphertext,12);return combined;
}
export async function open(bytes,keys) {
  if(bytes.length<29||bytes.length>MAX_BYTES+28)throw new Error('The encrypted voice is incomplete or too large.');
  const key=await crypto.subtle.importKey('raw',keys.encryption,'AES-GCM',false,['decrypt']);
  const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:utf8.encode('mimic.voice.v1')},key,bytes.slice(12));
  return validateArchive(JSON.parse(new TextDecoder().decode(plain)));
}
export async function encryptLabel(name,keys) {
  const nonce=crypto.getRandomValues(new Uint8Array(12)),key=await crypto.subtle.importKey('raw',keys.encryption,'AES-GCM',false,['encrypt']);
  const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:utf8.encode('mimic.name.v1')},key,utf8.encode(name)));
  const result=new Uint8Array(nonce.length+cipher.length);result.set(nonce);result.set(cipher,12);return base64(result);
}
export async function decryptLabel(label,keys) {
  const bytes=unbase64(label);if(bytes.length<29||bytes.length>512)throw new Error('Invalid voice label.');
  const key=await crypto.subtle.importKey('raw',keys.encryption,'AES-GCM',false,['decrypt']);
  return new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:utf8.encode('mimic.name.v1')},key,bytes.slice(12)));
}
export async function call(keys,action,{method='GET',body,signal,base=''}={}) {
  const response=await fetch(base+'/api/sync?action='+action,{method,signal,headers:{Authorization:keys.getAuthorization ? await keys.getAuthorization() : 'Bearer '+keys.token,...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const data=await response.json(); if(!response.ok)throw new Error(data.error||'Sync could not finish. Please try again.');return data;
}
export async function upload(archive,keys,options={}) {
  const id=await objectID(archive,keys), uploadID=hex(crypto.getRandomValues(new Uint8Array(16))), encrypted=await seal(archive,keys), count=Math.ceil(encrypted.length/CHUNK_BYTES);
  const manifest={id,upload:uploadID,parts:count,bytes:encrypted.length,label:await encryptLabel(archive.name,keys)};
  const started=await call(keys,'begin',{...options,method:'POST',body:manifest});
  if(started.complete)return id;
  for(let part=0;part<count;part++)await call(keys,'chunk',{...options,method:'POST',body:{id,upload:uploadID,part,data:base64(encrypted.slice(part*CHUNK_BYTES,(part+1)*CHUNK_BYTES))}});
  await call(keys,'commit',{...options,method:'POST',body:manifest});return id;
}
export async function download(id,keys,options={}) {
  const manifest=await call(keys,'manifest&id='+id,options);
  if(!Number.isInteger(manifest.parts)||manifest.parts<1||manifest.parts>65||manifest.bytes>MAX_BYTES+28)throw new Error('Invalid cloud voice size.');
  const output=new Uint8Array(manifest.bytes);let offset=0;
  for(let part=0;part<manifest.parts;part++) {const data=await call(keys,'chunk&id='+id+'&upload='+manifest.upload+'&part='+part,options);const bytes=unbase64(data.data);if(offset+bytes.length>output.length)throw new Error('Invalid cloud voice length.');output.set(bytes,offset);offset+=bytes.length;}
  if(offset!==output.length)throw new Error('The cloud voice is incomplete.');
  const archive=await open(output,keys);if(await objectID(archive,keys)!==id)throw new Error('The cloud voice identity does not match.');return archive;
}

export function generateRecoveryKey() { return hex(crypto.getRandomValues(new Uint8Array(32))); }
export async function recoveryVerifier(keys) {
  return hex(await crypto.subtle.digest('SHA-256',unhex(keys.token)));
}
export function devicePairingCode(root, device) {
  unhex(root);
  if(!/^[a-f0-9]{32}$/.test(device.id)||!/^[a-f0-9]{64}$/.test(device.secret))throw new Error('Invalid device credential.');
  return `mimic2.${root}.${device.id}.${device.secret}`;
}
