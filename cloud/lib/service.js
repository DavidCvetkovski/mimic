import {createHash,timingSafeEqual} from 'node:crypto';
export function authorised(header,expected) {
  if(!/^[0-9a-f]{64}$/.test(expected||''))return false;
  const token=/^Bearer ([0-9a-f]{64})$/.exec(header||'')?.[1];if(!token)return false;
  return timingSafeEqual(createHash('sha256').update(Buffer.from(token,'hex')).digest(),Buffer.from(expected,'hex'));
}
export const validID=id=>typeof id==='string'&&/^[0-9a-f]{64}$/.test(id);
export function partPath(id,part,upload){if(!/^[0-9a-f]{32}$/.test(upload||'')||!validID(id)||!Number.isInteger(part)||part<0||part>64)throw new Error('Invalid voice or part.');return `voices/${id}/${upload}/part-${String(part).padStart(2,'0')}`;}
export function manifestBody(body){if(!/^[0-9a-f]{32}$/.test(body?.upload||'')||!validID(body?.id)||!Number.isInteger(body.parts)||body.parts<1||body.parts>65||!Number.isInteger(body.bytes)||body.bytes<29||body.bytes>32*1024*1024+28||body.parts!==Math.ceil(body.bytes/(512*1024)))throw new Error('Invalid voice manifest.');if(typeof body.label!=="string"||body.label.length>512||!body.label.length)throw new Error("Invalid encrypted label.");return {id:body.id,upload:body.upload,parts:body.parts,bytes:body.bytes,label:body.label};}
