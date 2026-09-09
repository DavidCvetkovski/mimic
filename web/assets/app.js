import {Transport, LineDecoder, encodeWav, formatTime, slug, estimate, safeToStart} from './audio.js';
const $ = selector => document.querySelector(selector);
const SCRIPT = 'My name is — and this is my voice. I am reading a short paragraph so it can learn how I sound. The quick brown fox jumps over the lazy dog. Bright orange leaves fell through the cold November air, and somewhere further down the valley a church bell rang twice.';
const DEFAULT_TEXT = 'Every word of this was spoken by a model running on my own laptop, in a voice it learned from fifteen seconds of me reading a paragraph aloud.';
const read = (key, fallback) => { try { return localStorage.getItem('mimic.' + key) ?? fallback; } catch { return fallback; } };
const persist = (key, value) => { try { localStorage.setItem('mimic.' + key, value); return true; } catch { return false; } };
const state = {voices:[], chosen:read('voice', ''), run:null, current:null, transport:null, connected:false, health:null, storage:null, recording:null, recorded:null, recordingPending:false, saving:false, mutating:false, previewURL:null, sample:null, sampleName:null, sampleRun:0, page:'speak', rename:null, expected:0};
const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const message = (text, success = false) => { $('#message-text').textContent = text; $('#message').className = 'message' + (success ? ' success' : ''); $('#message').hidden = !text; };
const busy = () => Boolean(state.run || state.recording || state.recordingPending || state.saving || state.mutating);
async function request(path, {method='GET', body, signal} = {}) {
  const response = await fetch('/api' + path, {method, signal, headers:body === undefined ? {} : {'Content-Type':'application/json'}, ...(body === undefined ? {} : {body:JSON.stringify(body)})});
  if (!response.ok) {
    let detail; try { detail = (await response.json()).error; } catch {}
    throw new Error(detail || `The engine could not finish this request (${response.status}).`);
  }
  return response;
}
const json = async (path, options) => (await request(path, options)).json();
const voicePath = name => '/voices/' + encodeURIComponent(name);
function page(next) {
  state.page = ['speak','voices','settings'].includes(next) ? next : 'speak';
  document.querySelectorAll('.page').forEach(el => { el.hidden = el.id !== 'page-' + state.page; });
  document.querySelectorAll('[data-page]').forEach(el => { if (el.dataset.page === state.page) el.setAttribute('aria-current','page'); else el.removeAttribute('aria-current'); });
  history.replaceState(null, '', '#' + state.page);
  if (state.page !== 'voices') stopSample();
  if (state.page === 'settings') refreshStorage();
}
function setChosen(name) { state.chosen = name; persist('voice',name); paintVoices(); paintPlayer(); }
function updateText() {
  const text = $('#text').value;
  $('#estimate').textContent = '~' + formatTime(estimate(text)) + ' of audio';
  $('#character-count').textContent = text.length.toLocaleString() + ' / 10,000';
  $('#draft-state').textContent = persist('draft',text) ? 'Draft saved on this browser' : 'Draft storage unavailable';
  updateControls(); paintPlayer();
}
function updateControls() {
  const active = busy();
  $('#speak').disabled = !state.run && (!state.connected || active || !state.chosen || !$('#text').value.trim() || state.health?.model_ready === false);
  $('#speak').textContent = state.run ? 'Stop generating' : 'Speak it';
  $('#save').disabled = !state.current;
  $('#record').disabled = state.recordingPending || state.saving || state.mutating || Boolean(state.run) || !state.connected || state.health?.model_ready === false;
  $('#add').disabled = active || !state.recorded || !$('#name').value.trim() || !$('#said').value.trim();
  $('#close-record').disabled = Boolean(state.recording || state.recordingPending || state.saving);
  $('#name').disabled = state.saving; $('#said').disabled = state.saving;
  $('#new-voice').disabled = active; $('#first-record').disabled = active;
  $('#clear-cache').disabled = active || !state.storage?.cache;
  $('#unload').disabled = active || !state.health?.model_loaded;
  document.querySelectorAll('.voice-chip,.voice-actions button,.library-row .play-button,.preset').forEach(el => { el.disabled = active; });
}
function paintVoices() {
  $('#voice-count').textContent = state.voices.length;
  $('#first-voice').hidden = state.voices.length > 0;
  $('#voices').innerHTML = state.voices.map(voice => `<button class="voice-chip" data-select="${escapeHTML(voice.name)}" aria-pressed="${voice.name === state.chosen}">${escapeHTML(voice.name)}</button>`).join('');
  $('#library').innerHTML = state.voices.length ? state.voices.map(voice => `<article class="library-row"><button class="play-button" data-sample="${escapeHTML(voice.name)}" aria-label="${state.sampleName === voice.name ? 'Stop preview of' : 'Preview'} ${escapeHTML(voice.name)}">${state.sampleName === voice.name ? '■' : '▶'}</button><div class="voice-info"><h2>${escapeHTML(voice.name)}</h2><p>${voice.seconds ? Number(voice.seconds).toFixed(1) + 's reference recording' : 'Voice profile'}</p></div><div class="voice-actions">${voice.name === state.chosen ? '<span class="selected-label">✓ Selected</span>' : `<button class="text-button" data-select="${escapeHTML(voice.name)}">Use voice</button>`}<button class="text-button" data-export="${escapeHTML(voice.name)}">Export</button><button class="text-button" data-rename="${escapeHTML(voice.name)}">Rename</button><button class="text-button danger" data-delete="${escapeHTML(voice.name)}">Delete</button></div></article>`).join('') : '<div class="empty"><h2>No voices yet</h2><p>Record a short passage and give your words a familiar voice.</p><button class="primary" id="empty-record">Record a voice</button></div>';
  $('#empty-record')?.addEventListener('click', openRecording);
  updateControls();
}
async function loadVoices() {
  const data = await json('/voices'); state.voices = data.voices;
  if (!state.voices.some(v => v.name === state.chosen)) state.chosen = state.voices[0]?.name || '';
  persist('voice',state.chosen); paintVoices();
}
async function connect() {
  $('#connection').textContent = 'Connecting…';
  try {
    const [health] = await Promise.all([json('/health'),loadVoices()]);
    state.health = health; state.connected = true;
    $('#connection').textContent = health.model_ready ? 'Engine connected · private' : 'Voice model missing';
    $('#connection').className = 'connection ' + (health.model_ready ? 'ready' : 'offline');
    $('#engine-status').textContent = !health.model_ready ? 'The voice model is missing. Complete the engine setup, then reconnect.' : health.model_loaded ? 'The voice model is loaded and ready.' : 'Ready. The voice model will load when you need it.';
    if (!state.run && !state.current) $('#status').textContent = !health.model_ready ? 'Complete the engine setup to speak.' : state.chosen ? 'Ready when you are.' : 'Record a voice to get started.';
  } catch (error) {
    state.connected = false; $('#connection').textContent = 'Engine disconnected'; $('#connection').className = 'connection offline';
    message('Could not reach Mimic. Check that the local engine is running, then choose Reconnect in Settings.');
    $('#engine-status').textContent = 'The engine is unavailable.';
  }
  updateControls();
}
async function loadPresets() {
  try {
    const data = await json('/presets');
    $('#presets').replaceChildren(...data.presets.map(preset => {
      const button = document.createElement('button'); button.className = 'preset';
      const label = document.createElement('strong'); label.textContent = preset.label;
      const source = document.createElement('span'); source.textContent = preset.source;
      button.append(label,source); button.onclick = () => { $('#text').value = preset.text; updateText(); };
      return button;
    })); updateControls();
  } catch { $('#presets').textContent = 'Passages will appear when the engine is connected.'; }
}
async function refreshStorage() {
  try {
    state.storage = await json('/storage');
    const size = bytes => new Intl.NumberFormat(undefined,{maximumFractionDigits:1}).format(bytes / (bytes >= 1e9 ? 1e9 : 1e6)) + (bytes >= 1e9 ? ' GB' : ' MB');
    $('#storage').innerHTML = [['Voice model','model'],['Voices & recordings','voices'],['Cached audio','cache'],['Total','total']].map(([label,key]) => `<div><dt>${label}</dt><dd>${size(state.storage[key] || 0)}</dd></div>`).join('');
  } catch { $('#storage').innerHTML = '<div><dt>Storage unavailable. Reconnect to try again.</dt><dd>—</dd></div>'; }
  updateControls();
}
function stopSample() {
  state.sampleRun++; state.sample?.pause(); state.sample = null; state.sampleName = null;
}
async function sample(name) {
  const wasPlaying = state.sampleName === name; stopSample();
  if (wasPlaying) { paintVoices(); return; }
  state.transport?.pause(true); paintPlayer();
  const run = state.sampleRun;
  const audio = new Audio('/api' + voicePath(name) + '/sample.wav'); state.sample = audio; state.sampleName = name; paintVoices();
  audio.onended = () => { if (state.sample === audio) { stopSample(); paintVoices(); } };
  try { await audio.play(); } catch { if (run === state.sampleRun) { stopSample(); paintVoices(); message('There is no playable reference recording for this voice. You can still use its profile to speak.'); } }
}
function openRecording() {
  page('voices'); $('#record-panel').hidden = false;
  $('#record-panel').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth',block:'start'});
}
async function mutate(operation) {
  if (busy()) return;
  state.mutating = true; updateControls();
  try { await operation(); await loadVoices(); }
  catch (error) { message(error.message); }
  finally { state.mutating = false; updateControls(); }
}
document.addEventListener('click', event => {
  const target = event.target.closest('button'); if (!target || target.disabled) return;
  if (target.dataset.page) page(target.dataset.page);
  if (target.dataset.select) { setChosen(target.dataset.select); }
  if (target.dataset.sample) sample(target.dataset.sample);
  if (target.dataset.export) {
    mutate(async () => {
      const archive = await json(voicePath(target.dataset.export) + '/export');
      const url = URL.createObjectURL(new Blob([JSON.stringify(archive)], {type:'application/json'}));
      const link = document.createElement('a'); link.href = url; link.download = slug(target.dataset.export) + '.mimicvoice';
      document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url),1000);
    });
  }
  if (target.dataset.rename) {
    state.rename = target.dataset.rename; $('#rename-input').value = state.rename; $('#rename-error').textContent = ''; $('#rename-dialog').showModal(); $('#rename-input').select();
  }
  if (target.dataset.delete) {
    const name = target.dataset.delete;
    if (!confirm(`Delete “${name}” and its reference recording? This cannot be undone.`)) return;
    mutate(async () => { await json(voicePath(name),{method:'DELETE'}); stopSample(); if (state.current?.voice === name) resetPlayer(); message(`“${name}” was deleted.`,true); });
  }
});
$('#rename-form').onsubmit = async event => {
  event.preventDefault(); const old = state.rename, name = $('#rename-input').value.trim(); if (!name || busy()) return;
  state.mutating = true; $('#rename-submit').disabled = true; $('#rename-cancel').disabled = true;
  try {
    await json(voicePath(old) + '/rename',{method:'POST',body:{name}}); stopSample();
    if (state.current?.voice === old) state.current.voice = name;
    if (state.chosen === old) state.chosen = name;
    await loadVoices(); paintPlayer(); $('#rename-dialog').close(); message('Voice renamed.',true);
  } catch (error) { $('#rename-error').textContent = error.message; }
  finally { state.mutating = false; $('#rename-submit').disabled = false; $('#rename-cancel').disabled = false; updateControls(); }
};
$('#rename-cancel').onclick = () => $('#rename-dialog').close();
$('#rename-dialog').addEventListener('cancel',event => { if (state.mutating) event.preventDefault(); });

function resetPlayer() {
  state.transport?.reset(); state.current = null; state.expected = 0;
  $('#player').hidden = true; $('#generation').hidden = true; $('#save').disabled = true; paintPlayer();
}
function paintPlayer() {
  const transport = state.transport; if (!transport) return;
  transport.tick();
  $('#play').textContent = transport.playing ? 'Ⅱ' : '▶'; $('#play').setAttribute('aria-label',transport.playing ? 'Pause audio' : 'Play audio');
  $('#play').disabled = !transport.buffered;
  const total = transport.done ? transport.buffered : Math.max(state.expected,transport.buffered);
  $('#seek').max = Math.max(total,0.01); $('#seek').value = transport.position; $('#seek').disabled = !transport.buffered;
  $('#seek').setAttribute('aria-valuetext',`${formatTime(transport.position)} of ${formatTime(total)}`);
  $('#play-clock').textContent = `${formatTime(transport.position)} / ${transport.done ? '' : '~'}${formatTime(total)}`;
  const origin = state.current || state.run;
  $('#now-playing').textContent = origin ? origin.voice + ((origin.voice !== state.chosen || origin.text !== $('#text').value.trim()) ? ' · previous version' : '') : '';
  $('#generation').value = transport.done ? 1 : Math.min(.98,transport.buffered / Math.max(total,.01));
}
function stopRun() {
  const run = state.run; if (!run) return;
  state.run = null; run.controller.abort(); resetPlayer(); $('#status').textContent = 'Stopped. Ready to try again.'; updateControls();
}
async function speak() {
  if (state.run) { stopRun(); return; }
  if ($('#speak').disabled) return;
  message(''); stopSample(); $('#preview').pause();
  const run = {controller:new AbortController(),voice:state.chosen,text:$('#text').value.trim()};
  state.run = run; resetPlayer(); updateControls(); $('#status').textContent = 'Preparing your voice…';
  const isCurrent = () => state.run === run;
  try {
    if (!state.transport) { const Context = window.AudioContext || window.webkitAudioContext; if (!Context) throw new Error('This browser does not support audio playback. Try a recent Safari, Chrome, or Firefox.'); state.transport = new Transport(new Context()); }
    await state.transport.context.resume(); if (!isCurrent()) return;
    $('#player').hidden = false; $('#generation').hidden = false;
    const response = await request('/speak/stream',{method:'POST',body:{text:run.text,voice:run.voice},signal:run.controller.signal});
    if (!isCurrent()) return;
    if (!response.body) throw new Error('This browser cannot receive streaming audio.');
    const reader = response.body.getReader(), lines = new LineDecoder();
    let rate = 44100, rtf = 1.2, completed = false;
    const event = async data => {
      if (!isCurrent()) return;
      if (completed) throw new Error('The engine sent audio after the passage was complete.');
      if (data.type === 'error') throw new Error(data.message || 'The engine could not generate this passage.');
      if (data.type === 'start') {
        if (!Number.isFinite(data.sample_rate) || data.sample_rate < 8000 || data.sample_rate > 192000) throw new Error('The engine returned an invalid audio rate.');
        rate = data.sample_rate; state.expected = Number(data.estimate) || estimate(run.text); $('#status').textContent = `Preparing about ${formatTime(state.expected)} of audio…`;
      } else if (data.type === 'chunk') {
        const bytes = Uint8Array.from(atob(data.pcm),c => c.charCodeAt(0));
        if (!bytes.length || bytes.length % 2) throw new Error('The engine returned an incomplete audio chunk.');
        const pcm = new DataView(bytes.buffer), buffer = state.transport.context.createBuffer(1,bytes.length / 2,rate), channel = buffer.getChannelData(0);
        for (let i=0;i<channel.length;i++) channel[i] = pcm.getInt16(i*2,true) / 32768;
        state.transport.append(buffer); rtf = Math.max(rtf,Number(data.rtf) || rtf);
        if (safeToStart(state.transport.buffered,Math.max(state.expected,state.transport.buffered),rtf)) state.transport.play();
        $('#status').textContent = `Making sentence ${data.index + 1} of ${data.of}…`;
      } else if (data.type === 'done') {
        let blob;
        if (data.cached && data.wav) {
          const bytes = Uint8Array.from(atob(data.wav),c => c.charCodeAt(0));
          const buffer = await state.transport.context.decodeAudioData(bytes.buffer.slice(0)); if (!isCurrent()) return;
          state.transport.append(buffer); blob = new Blob([bytes],{type:'audio/wav'});
        } else blob = state.transport.wav();
        if (!state.transport.buffered) throw new Error('No audio was generated. Try a shorter passage.');
        completed = true; state.transport.done = true; state.current = {blob,voice:run.voice,text:run.text};
        state.transport.play(); $('#status').textContent = data.cached ? 'Ready · from your saved audio' : `Ready · ${formatTime(state.transport.buffered)} of audio`;
      }
      paintPlayer();
    };
    try {
      while (true) {
        const {done,value} = await reader.read(); if (!isCurrent()) return;
        for (const item of lines.push(value,done)) await event(item);
        if (done) break;
      }
      if (!completed) throw new Error('The connection ended before the audio was finished. Please try again.');
    } finally { if (!completed) await reader.cancel().catch(() => {}); reader.releaseLock(); }
  } catch (error) {
    if (isCurrent()) { resetPlayer(); $('#status').textContent = 'Could not finish this passage.'; if (error.name !== 'AbortError') message(error.message || 'Could not connect to the voice engine.'); }
  } finally {
    if (isCurrent()) { state.run = null; $('#generation').hidden = true; updateControls(); paintPlayer(); }
  }
}
$('#speak').onclick = speak;
$('#play').onclick = async () => {
  if (!state.transport) return;
  if (state.transport.playing) state.transport.pause(true);
  else { stopSample(); $('#preview').pause(); try { await state.transport.context.resume(); state.transport.play(true); } catch { message('Audio playback is unavailable. Please try again.'); } }
  paintPlayer();
};
$('#seek').oninput = () => { state.transport?.seek(Number($('#seek').value)); paintPlayer(); };
$('#save').onclick = () => {
  if (!state.current) return;
  const link = document.createElement('a'), url = URL.createObjectURL(state.current.blob);
  link.href = url; link.download = `${slug(state.current.voice)}-${slug(state.current.text).slice(0,45)}.wav`;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url),1000);
};
setInterval(() => { if (state.transport?.playing || state.run) paintPlayer(); },100);

function discardRecording() {
  state.recorded = null; $('#preview').pause(); $('#preview').removeAttribute('src'); $('#preview').hidden = true;
  if (state.previewURL) URL.revokeObjectURL(state.previewURL); state.previewURL = null;
  $('#record-clock').textContent = '0.0s'; $('#level').value = 0; $('#record').textContent = 'Start recording';
  updateControls();
}
async function finishRecording() {
  const capture = state.recording; if (!capture || capture.stopping) return;
  capture.stopping = true; state.recordingPending = true; updateControls();
  clearInterval(capture.timer); capture.source.disconnect();
  // Drain the worklet's final partial block before releasing the microphone.
  await new Promise(resolve => { capture.flushed = resolve; capture.node.port.postMessage('flush'); setTimeout(resolve,250); });
  capture.node.disconnect(); capture.stream.getTracks().forEach(track => track.stop());
  await capture.context.close().catch(() => {}); state.recording = null; state.recordingPending = false;
  const length = capture.chunks.reduce((sum,item) => sum + item.length,0), seconds = length / capture.rate;
  $('#level').value = 0; $('#record-clock').textContent = seconds.toFixed(1) + 's'; $('#record').textContent = 'Record again';
  if (seconds < 3) { message('That recording was too short. Read for at least three seconds; around fifteen works best.'); updateControls(); return; }
  if (capture.peak < .003) { message('The microphone picked up almost no sound. Check your input and try again.'); updateControls(); return; }
  const samples = new Float32Array(length); let at = 0;
  for (const chunk of capture.chunks) { samples.set(chunk,at); at += chunk.length; }
  state.recorded = encodeWav(samples,capture.rate);
  state.previewURL = URL.createObjectURL(new Blob([state.recorded],{type:'audio/wav'}));
  $('#preview').src = state.previewURL; $('#preview').hidden = false;
  $('#record-hint').textContent = 'Listen once, check the transcript, and give your voice a name.'; updateControls();
}
$('#record').onclick = async () => {
  if (state.recording) { await finishRecording(); return; }
  if (busy()) return;
  message(''); state.recordingPending = true; stopSample(); state.transport?.pause(true); discardRecording(); updateControls();
  let stream, context, node, source;
  try {
    if (!navigator.mediaDevices?.getUserMedia || !window.isSecureContext) throw new Error('Microphone access needs a secure connection. Open Mimic at http://127.0.0.1:8455 on the computer running the engine, or use HTTPS.');
    stream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:false,noiseSuppression:false,autoGainControl:false}});
    const Context = window.AudioContext || window.webkitAudioContext; context = new Context();
    if (!context.audioWorklet) throw new Error('Recording needs a browser with AudioWorklet support. Please use a recent Safari, Chrome, or Firefox.');
    await context.audioWorklet.addModule('/assets/recorder.js'); await context.resume();
    source = context.createMediaStreamSource(stream); node = new AudioWorkletNode(context,'mimic-recorder',{channelCount:1,channelCountMode:'explicit'});
    const capture = {context,node,source,stream,rate:context.sampleRate,chunks:[],peak:0,started:performance.now(),stopping:false};
    state.recording = capture;
    node.port.onmessage = event => {
      if (event.data.done) { capture.flushed?.(); return; }
      const samples = event.data.samples; if (!samples || state.recording !== capture) return;
      capture.chunks.push(samples); let peak = 0;
      for (const sample of samples) peak = Math.max(peak,Math.abs(sample));
      capture.peak = Math.max(capture.peak,peak); $('#level').value = Math.min(1,peak*3);
    };
    source.connect(node); node.connect(context.destination);
    capture.timer = setInterval(() => {
      const seconds = (performance.now() - capture.started)/1000; $('#record-clock').textContent = seconds.toFixed(1) + 's';
      if (seconds >= 30) finishRecording();
    },100);
    stream.getTracks().forEach(track => { track.onended = () => { if (state.recording === capture) finishRecording(); }; });
    $('#record').textContent = 'Stop recording'; $('#record-hint').textContent = 'Read naturally. Aim for 10–20 seconds.';
  } catch (error) {
    source?.disconnect(); node?.disconnect(); stream?.getTracks().forEach(track => track.stop()); await context?.close().catch(() => {});
    message(error.name === 'NotAllowedError' ? 'Microphone access was denied. Allow it in your browser’s site settings, then try recording again.' : error.name === 'NotFoundError' ? 'No microphone was found. Connect one and try again.' : error.message);
  } finally { state.recordingPending = false; updateControls(); }
};
$('#add').onclick = async () => {
  const name = $('#name').value.trim(), transcript = $('#said').value.trim(); if (busy() || !state.recorded || !name || !transcript) return;
  const overwrite = state.voices.some(voice => voice.name === name);
  if (overwrite && !confirm(`Replace “${name}” with this recording? Its current profile cannot be recovered.`)) return;
  state.saving = true; updateControls(); $('#add-status').textContent = 'Learning your voice…';
  try {
    const parts = []; for (const byte of state.recorded) parts.push(byte.toString(16).padStart(2,'0'));
    await json('/voices',{method:'POST',body:{name,transcript,wav_hex:parts.join(''),overwrite}});
    state.chosen = name; if (state.current?.voice === name) resetPlayer();
    discardRecording(); $('#name').value = ''; $('#said').value = SCRIPT; $('#record-panel').hidden = true;
    await loadVoices(); page('speak'); message(`“${name}” is ready and selected. Try a passage to hear it.`,true);
  } catch (error) { message(error.message); }
  finally { state.saving = false; $('#add-status').textContent = ''; updateControls(); }
};
$('#name').oninput = updateControls; $('#said').oninput = updateControls;
$('#preview').onplay = () => { stopSample(); state.transport?.pause(true); paintPlayer(); paintVoices(); };
$('#close-record').onclick = () => { if (state.recorded && !confirm('Discard this unsaved recording?')) return; discardRecording(); $('#record-panel').hidden = true; };
$('#clear-cache').onclick = () => {
  if (!confirm('Clear generated audio from the cache? Your voices and model will stay.')) return;
  mutate(async () => { const data = await json('/cache',{method:'DELETE'}); state.storage = data.storage; await refreshStorage(); message('Cached audio cleared. Your voices are ready to use.',true); });
};
$('#unload').onclick = () => mutate(async () => { await json('/model/unload',{method:'POST',body:{}}); await connect(); message('Model memory released. It will load again when you speak.',true); });
$('#refresh').onclick = refreshStorage;
$('#reconnect').onclick = async () => { message(''); await Promise.all([connect(),loadPresets(),refreshStorage()]); };
$('#dismiss-message').onclick = () => message('');
$('#manage-voices').onclick = () => page('voices');
$('#new-voice').onclick = openRecording; $('#first-record').onclick = openRecording;
$('#text').oninput = updateText;
document.addEventListener('keydown',event => {
  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !$('#rename-dialog').open && state.page === 'speak' && !$('#speak').disabled) { event.preventDefault(); speak(); }
  if (event.key === 'Escape' && state.run) stopRun();
});
window.addEventListener('hashchange',() => page(location.hash.slice(1)));
window.addEventListener('beforeunload',event => {
  if (state.recording || state.recorded || state.saving) { event.preventDefault(); event.returnValue = ''; }
});
window.addEventListener('pagehide',() => {
  stopRun(); stopSample(); state.transport?.pause();
  const capture = state.recording; if (capture) { clearInterval(capture.timer); capture.stream.getTracks().forEach(track => track.stop()); capture.context.close().catch(() => {}); }
});
document.addEventListener('visibilitychange',() => { if (document.hidden && state.recording) finishRecording(); });
$('#text').value = read('draft',DEFAULT_TEXT); $('#script').textContent = SCRIPT; $('#said').value = SCRIPT;
updateText(); page(location.hash.slice(1)); Promise.all([connect(),loadPresets()]);

$('#import-voice').onchange = async event => {
  const file = event.target.files[0]; if (!file || busy()) return;
  await mutate(async () => {
    if (file.size > 32 * 1024 * 1024) throw new Error('Choose a voice smaller than 32 MiB.');
    const archive = JSON.parse(await file.text());
    await json('/voices/import', {method:'POST', body:archive});
    message('Voice imported. It is ready to speak.',true);
  });
  event.target.value = '';
};
