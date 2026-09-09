// Audio transport is independent of the page so timeline and pause behavior can
// be checked without a model, microphone, or browser audio device.
export const formatTime = seconds => {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`;
};
export const slug = name => String(name || 'mimic').normalize('NFKD')
  .replace(/[^\w\s-]/g, '').trim().replace(/[\s_]+/g, '-').toLowerCase() || 'mimic';
export const estimate = text => Math.max(0, text.trim().replace(/\s+/g, ' ').length * 0.0647);
export const safeToStart = (buffered, total, rtf) => {
  const rate = Math.max(1, Number(rtf) || 1);
  return buffered > 0 && (buffered >= total || buffered >= total * (rate - 1) / rate * 1.35);
};

export function encodeWav(samples, rate) {
  const bytes = new Uint8Array(44 + samples.length * 2);
  const view = new DataView(bytes.buffer);
  const put = (at, text) => [...text].forEach((c, i) => view.setUint8(at + i, c.charCodeAt(0)));
  put(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true);
  put(8, 'WAVEfmt '); view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  put(36, 'data'); view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    const value = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(44 + i * 2, Math.round(value * (value < 0 ? 32768 : 32767)), true);
  }
  return bytes;
}

export class LineDecoder {
  constructor() { this.decoder = new TextDecoder(); this.pending = ''; }
  push(bytes, final = false) {
    this.pending += this.decoder.decode(bytes, {stream: !final});
    const lines = this.pending.split('\n');
    this.pending = final ? '' : lines.pop();
    return lines.filter(line => line.trim()).map(line => JSON.parse(line));
  }
}

export class Transport {
  constructor(context) { this.context = context; this.buffers = []; this.sources = []; this.buffered = 0; this.offset = 0; this.startedAt = 0; this.playing = false; this.done = false; this.userPaused = false; }
  get position() {
    return Math.min(this.buffered, this.offset + (this.playing ? Math.max(0, this.context.currentTime - this.startedAt) : 0));
  }
  schedule(buffer, when, offset = 0) {
    const source = this.context.createBufferSource();
    source.buffer = buffer; source.connect(this.context.destination);
    source.onended = () => { source.disconnect(); this.sources = this.sources.filter(item => item !== source); };
    source.start(when, offset); this.sources.push(source);
  }
  append(buffer) {
    // If generation fell behind, rebase the timeline at the actual next sound.
    // Without this, the clock keeps advancing through silence and skips audio.
    if (this.playing && this.position >= this.buffered) {
      this.offset = this.buffered; this.startedAt = this.context.currentTime;
    }
    const at = this.startedAt + this.buffered - this.offset;
    this.buffers.push(buffer); this.buffered += buffer.duration;
    if (this.playing) this.schedule(buffer, Math.max(at, this.context.currentTime));
  }
  play(manual = false) {
    if (manual) this.userPaused = false;
    if (this.playing || !this.buffers.length || this.userPaused) return;
    if (this.done && this.offset >= this.buffered - 0.001) this.offset = 0;
    this.playing = true; this.startedAt = this.context.currentTime;
    let skip = this.offset, at = this.startedAt;
    for (const buffer of this.buffers) {
      if (skip >= buffer.duration) { skip -= buffer.duration; continue; }
      this.schedule(buffer, at, skip); at += buffer.duration - skip; skip = 0;
    }
  }
  pause(manual = false) {
    if (manual) this.userPaused = true;
    this.offset = this.position; this.playing = false;
    for (const source of this.sources) { source.onended = null; try { source.stop(); } catch {} source.disconnect(); }
    this.sources = [];
  }
  seek(seconds) {
    const playing = this.playing;
    this.pause(); this.offset = Math.max(0, Math.min(Number(seconds) || 0, this.buffered));
    if (playing && this.offset < this.buffered) this.play();
  }
  tick() { if (this.done && this.playing && this.position >= this.buffered) this.pause(); }
  reset() { this.pause(); this.buffers = []; this.buffered = 0; this.offset = 0; this.done = false; this.userPaused = false; }
  wav() {
    const length = this.buffers.reduce((sum, buffer) => sum + buffer.length, 0);
    const samples = new Float32Array(length); let at = 0;
    for (const buffer of this.buffers) { samples.set(buffer.getChannelData(0), at); at += buffer.length; }
    return new Blob([encodeWav(samples, this.buffers[0]?.sampleRate || 44100)], {type: 'audio/wav'});
  }
}
