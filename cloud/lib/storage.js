import {get, put, list, del, head, BlobNotFoundError, BlobPreconditionFailedError, BlobPathnameMismatchError} from '@vercel/blob';
export const blob = {get, put, list, del, head};
export async function readJSON(path) {
  const result = await get(path, {access:'private', useCache:false});
  if (!result) return null;
  return {value:await new Response(result.stream).json(), etag:result.blob.etag};
}
export async function writeJSON(path, value, etag) {
  return put(path, JSON.stringify(value), {access:'private', addRandomSuffix:false,
    allowOverwrite:Boolean(etag), ...(etag ? {ifMatch:etag} : {}),
    contentType:'application/json', cacheControlMaxAge:60});
}
export function conflict(error) {
  return error instanceof BlobPreconditionFailedError || error instanceof BlobPathnameMismatchError
    || (error.message?.includes('already exists') && error.message?.startsWith('Vercel Blob:'));
}
export async function updateJSON(path, transform) {
  for (let attempt=0; attempt<5; attempt++) {
    const current=await readJSON(path);
    const next=await transform(current?.value ?? null);
    try { await writeJSON(path,next,current?.etag); return next; }
    catch (error) { if (!conflict(error)) throw error; }
  }
  throw new HttpError(409,'Your library changed. Please try again.');
}
export class HttpError extends Error {
  constructor(status,message) {super(message);this.status=status;}
}
export const missing = error => error instanceof BlobNotFoundError;
