import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../../web/assets/audio.js',import.meta.url),'utf8');
const {Transport,LineDecoder,encodeWav,formatTime,slug,safeToStart} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const buffer = duration => ({duration,length:duration*10,sampleRate:10,getChannelData:() => new Float32Array(duration*10)});
function context() { return {currentTime:0,destination:{},scheduled:[],createBufferSource() { const ctx=this; return {connect(){},disconnect(){},stop(){this.stopped=true;},start(at,offset=0){ctx.scheduled.push({at,offset,node:this});}}; }}; }
test('pause remains paused when more chunks arrive and when synthesis completes',() => {
  const ctx=context(), audio=new Transport(ctx); audio.append(buffer(4)); audio.play(); ctx.currentTime=1; audio.pause(true); audio.append(buffer(3)); audio.done=true; audio.play();
  assert.equal(audio.playing,false); assert.equal(audio.position,1); assert.equal(ctx.scheduled.length,1);
  audio.play(true); assert.equal(audio.playing,true); assert.equal(ctx.scheduled[1].offset,1);
});
test('underrun rebases playback so late chunks retain their full duration',() => {
  const ctx=context(), audio=new Transport(ctx); audio.append(buffer(2)); audio.play(); ctx.currentTime=8; audio.append(buffer(3));
  assert.equal(audio.position,2); assert.equal(ctx.scheduled[1].at,8); ctx.currentTime=9; assert.equal(audio.position,3);
  audio.done=true; ctx.currentTime=11; audio.tick(); assert.equal(audio.position,5); assert.equal(audio.playing,false);
});
test('finished playback can replay from the beginning',() => {
  const ctx=context(), audio=new Transport(ctx); audio.append(buffer(2)); audio.done=true; audio.play(); ctx.currentTime=2; audio.tick(); audio.play(true);
  assert.equal(audio.position,0); assert.equal(ctx.scheduled.at(-1).offset,0);
});
test('stop resets old sources, pause state, buffers and playback position',() => {
  const ctx=context(), audio=new Transport(ctx); audio.append(buffer(3)); audio.play(); ctx.currentTime=1; audio.reset();
  assert.equal(ctx.scheduled[0].node.stopped,true); assert.equal(audio.position,0); assert.equal(audio.buffered,0); assert.equal(audio.playing,false);
  audio.append(buffer(1)); audio.play(); assert.equal(audio.playing,true);
});
test('seeking uses playable duration and preserves paused state',() => {
  const ctx=context(), audio=new Transport(ctx); audio.append(buffer(2)); audio.append(buffer(3)); audio.seek(99); assert.equal(audio.position,5); assert.equal(audio.playing,false);
  audio.seek(-2); assert.equal(audio.position,0); audio.play(); audio.seek(3); assert.equal(ctx.scheduled.at(-1).offset,1);
});
test('stream parser handles UTF-8 split across reads and final line without newline',() => {
  const bytes=new TextEncoder().encode('{"name":"Zoë"}\n{"done":true}'), parser=new LineDecoder(); let events=[];
  for (const byte of bytes) events.push(...parser.push(new Uint8Array([byte])));
  events.push(...parser.push(undefined,true)); assert.deepEqual(events,[{name:'Zoë'},{done:true}]);
});
test('stream parser rejects incomplete JSON at EOF',() => {
  const parser=new LineDecoder(); parser.push(new TextEncoder().encode('{"done":')); assert.throws(() => parser.push(undefined,true),SyntaxError);
});
test('WAV output has correct rate, length, clipping and little-endian PCM',() => {
  const bytes=encodeWav(new Float32Array([-2,-1,0,1,2]),44100), view=new DataView(bytes.buffer);
  assert.equal(new TextDecoder().decode(bytes.slice(0,4)),'RIFF'); assert.equal(view.getUint32(24,true),44100); assert.equal(view.getUint32(40,true),10);
  assert.deepEqual(Array.from({length:5},(_,i) => view.getInt16(44+i*2,true)),[-32768,-32768,0,32767,32767]);
});
test('buffer threshold protects slow generation and never starts on an empty queue',() => {
  assert.equal(safeToStart(0,0,1),false); assert.equal(safeToStart(2,20,3),false); assert.equal(safeToStart(19,20,3),true); assert.equal(safeToStart(20,20,99),true);
});
test('filenames and time labels remain usable for Unicode and invalid values',() => {
  assert.equal(slug('Zoë, reading'),'zoe-reading'); assert.equal(slug('你好'),'mimic'); assert.equal(formatTime(-1),'0:00'); assert.equal(formatTime(65.9),'1:05');
});
