import test from 'node:test';
import assert from 'node:assert/strict';
import {BlobNotFoundError} from '@vercel/blob';
import {newAccount,reserveUpload,equalHash,deviceCredentials,digest,checkOrigin} from '../lib/accounts.js';
import {createSyncHandler} from '../api/sync.js';
import {credentials,generateRecoveryKey,recoveryVerifier,devicePairingCode} from '../lib/vault.js';
import {HttpError} from '../lib/storage.js';
const A='a'.repeat(64), B='b'.repeat(64), id='c'.repeat(64), upload='d'.repeat(32);
const manifest={id,upload,parts:1,bytes:32,label:'encrypted-label'};
function fixture(){
 const records=new Map(),accounts=new Map([[A,newAccount(A,A)],[B,newAccount(B,B)]]);
 const store={
  head:async path=>{if(!records.has(path))throw new BlobNotFoundError();return {size:records.get(path).length};},
  put:async(path,data)=>{records.set(path,Buffer.from(data));},
  get:async path=>records.has(path)?{stream:new Response(records.get(path)).body}:null,
  list:async({prefix})=>({blobs:[...records.keys()].filter(k=>k.startsWith(prefix)).map(pathname=>({pathname,uploadedAt:new Date(0)})),hasMore:false})
 };
 const handler=createSyncHandler({store,authenticate:async req=>{
  const id=req.headers.authorization;if(!accounts.has(id))throw new HttpError(401,'Unauthorized');
  return {id,kind:'session',prefix:accounts.get(id).prefix};
 },readJSON:async path=>({value:accounts.get(path.split('/')[1])}),updateJSON:async(path,fn)=>{const id=path.split('/')[1],next=fn(accounts.get(id));accounts.set(id,next);return next;}});
 async function request(user,action,body,query={}){let status=200,result;const res={setHeader(){},status(s){status=s;return this;},json(v){result=v;return this;}};await handler({method:body?'POST':'GET',headers:{authorization:user},query:{action,...query},body},res);return {status,result};}
 return {records,accounts,request};
}
test('account identifiers never use email addresses or client-chosen storage paths',()=>{
 assert.notEqual(newAccount(A,A).prefix,newAccount(B,A).prefix);
 assert.throws(()=>newAccount('../private',A));assert.equal(equalHash(A,A),true);assert.equal(equalHash(A,B),false);
 assert.throws(()=>deviceCredentials('Device ../../x.y'));assert.equal(deviceCredentials('Device '+upload+'.'+A).hash,digest(Buffer.from(A,'hex')));
 assert.throws(()=>checkOrigin({headers:{origin:'https://attacker.example'}}));
});
test('recovery keys are random, verifier contains no root key, pairing codes preserve separate device secrets',async()=>{
 const root=generateRecoveryKey();assert.match(root,/^[a-f0-9]{64}$/);assert.notEqual(root,generateRecoveryKey());
 const verifier=await recoveryVerifier(await credentials(root));assert.notEqual(root,verifier);
 assert.equal(devicePairingCode(root,{id:upload,secret:A}),`mimic2.${root}.${upload}.${A}`);
});
test('quota reservations count incomplete uploads and reject replacement or oversized reservations',()=>{
 let a=reserveUpload(newAccount(A,A),manifest);assert.equal(Object.keys(a.uploads).length,1);
 assert.equal(reserveUpload(a,manifest),a);assert.throws(()=>reserveUpload(a,{...manifest,upload:'e'.repeat(32)}));
 for(let n=0;n<7;n++)a=reserveUpload(a,{...manifest,id:n.toString(16).padStart(64,'0'),bytes:32*1048576});
 assert.throws(()=>reserveUpload(a,{...manifest,id:B,bytes:32*1048576}),/limit/);
});
test('tenant isolation covers list, manifest, chunk and writes, even with identical object IDs',async()=>{
 process.env.BLOB_STORE_ID='test-store';const {request,records}=fixture();
 assert.equal((await request('unknown','list')).status,401);
 assert.equal((await request(A,'chunk',{id,upload,part:0,data:Buffer.alloc(32).toString('base64')})).status,409);
 for(const [user,value] of [[A,1],[B,2]]){
  assert.equal((await request(user,'begin',manifest)).status,200);
  assert.equal((await request(user,'chunk',{id,upload,part:0,data:Buffer.alloc(32,value).toString('base64')})).status,200);
  assert.equal((await request(user,'commit',manifest)).status,200);
 }
 assert.equal(records.size,4);
 for(const [user,value] of [[A,1],[B,2]]){
  assert.deepEqual((await request(user,'list')).result.voices.map(v=>v.id),[id]);
  assert.equal(Buffer.from((await request(user,'chunk',null,{id,upload,part:'0'})).result.data,'base64')[0],value);
  assert.equal((await request(user,'manifest',null,{id:A})).status,404);
  assert.equal((await request(user,'begin',{...manifest,upload:'e'.repeat(32)})).result.complete,true);
 }
 assert.equal((await request(A,'manifest',null,{id:'../'+B})).status,400);
});
test('incomplete and mismatched uploads cannot become visible',async()=>{
 process.env.BLOB_STORE_ID='test-store';const {request}=fixture();
 await request(A,'begin',manifest);
 assert.equal((await request(A,'commit',manifest)).status,404);
 assert.equal((await request(A,'chunk',{id,upload,part:0,data:Buffer.alloc(31).toString('base64')})).status,400);
 assert.deepEqual((await request(A,'list')).result.voices,[]);
});

test('revoked, unknown, and removed devices fail while active devices resolve only their owner',async()=>{
 const {authenticate}=await import('../lib/accounts.js');
 let device={accountId:A,secretHash:digest(Buffer.from(B,'hex')),revoked:false};
 let account={...newAccount(A,A),devices:[upload]};
 const read=async path=>({value:path.startsWith('devices/')?device:account});
 const req={headers:{authorization:`Device ${upload}.${B}`}};
 assert.equal((await authenticate(req,{read})).prefix,`vaults/${A}/`);
 device={...device,revoked:true};await assert.rejects(authenticate(req,{read}),/removed/);
 device={...device,revoked:false,secretHash:A};await assert.rejects(authenticate(req,{read}));
 device={...device,secretHash:digest(Buffer.from(B,'hex'))};account={...account,devices:[]};await assert.rejects(authenticate(req,{read}),/no longer/);
});
