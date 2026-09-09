// Send blocks of PCM to the page while emitting silence to the output device.
class MimicRecorder extends AudioWorkletProcessor {
  constructor() {
    super(); this.block = new Float32Array(4096); this.used = 0;
    this.port.onmessage = event => {
      if (event.data === 'flush') { this.flush(); this.port.postMessage({done:true}); }
    };
  }
  flush() {
    if (!this.used) return;
    const samples = this.block.slice(0, this.used);
    this.port.postMessage({samples}, [samples.buffer]); this.used = 0;
  }
  process(inputs) {
    const input = inputs[0]?.[0];
    if (input) for (const sample of input) {
      this.block[this.used++] = sample;
      if (this.used === this.block.length) this.flush();
    }
    return true;
  }
}
registerProcessor('mimic-recorder', MimicRecorder);
