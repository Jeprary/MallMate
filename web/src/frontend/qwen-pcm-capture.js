class PcmCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.outputRate = 16000;
    this.buffer = new ArrayBuffer(this.outputRate / 10 * 2);
    this.view = new DataView(this.buffer);
    this.offset = 0;
    this.sampleLimit = options?.processorOptions?.maxSamples ?? Infinity;
    this.samplesWritten = 0;
    this.weight = 0;
    this.sum = 0;
    this.port.onmessage = () => this.finish();
  }

  finish() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.weight && this.samplesWritten < this.sampleLimit) this.write(this.sum / this.weight);
    this.flush();
    this.port.postMessage('done');
  }

  write(sample) {
    this.view.setInt16(this.offset, sample * (sample < 0 ? 32768 : 32767), true);
    this.offset += 2;
    this.samplesWritten++;
    if (this.offset === this.buffer.byteLength) this.flush();
  }

  flush() {
    if (!this.offset) return;
    const frame = this.buffer.slice(0, this.offset);
    this.port.postMessage(frame, [frame]);
    this.offset = 0;
  }

  process(inputs) {
    if (this.stopped) return false;
    for (const sample of inputs[0]?.[0] || []) {
      const value = Math.max(-1, Math.min(1, sample));
      // Integrate source samples over each output interval, including partial boundaries.
      let remaining = this.outputRate;
      while (remaining > 0) {
        const part = Math.min(remaining, sampleRate - this.weight);
        this.sum += value * part;
        this.weight += part;
        remaining -= part;
        if (this.weight === sampleRate) {
          this.write(this.sum / sampleRate);
          this.weight = 0;
          this.sum = 0;
          if (this.samplesWritten === this.sampleLimit) {
            this.finish();
            return false;
          }
        }
      }
    }
    return true;
  }
}

registerProcessor('pcm-capture', PcmCapture);
