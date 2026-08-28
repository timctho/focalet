export const MAX_PROTOCOL_FRAME_BYTES = 16 * 1024 * 1024;

export class BoundedLineDecoder {
  constructor({ onLine, onOversized, maxFrameBytes = MAX_PROTOCOL_FRAME_BYTES }) {
    if (typeof onLine !== 'function') throw new TypeError('BoundedLineDecoder requires an onLine callback.');
    this.onLine = onLine;
    this.onOversized = typeof onOversized === 'function' ? onOversized : () => {};
    this.maxFrameBytes = maxFrameBytes;
    this.buffer = '';
    this.discardingOversizedLine = false;
  }

  push(chunk) {
    let input = String(chunk ?? '');
    while (input) {
      if (this.discardingOversizedLine) {
        const newline = input.indexOf('\n');
        if (newline < 0) return;
        this.discardingOversizedLine = false;
        input = input.slice(newline + 1);
        continue;
      }

      const newline = input.indexOf('\n');
      if (newline < 0) {
        this.buffer += input;
        if (Buffer.byteLength(this.buffer, 'utf8') > this.maxFrameBytes) {
          this.buffer = '';
          this.discardingOversizedLine = true;
          this.onOversized();
        }
        return;
      }

      let line = `${this.buffer}${input.slice(0, newline)}`;
      this.buffer = '';
      input = input.slice(newline + 1);
      if (Buffer.byteLength(line, 'utf8') > this.maxFrameBytes) {
        this.onOversized();
        continue;
      }
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (line) this.onLine(line);
    }
  }

  reset() {
    this.buffer = '';
    this.discardingOversizedLine = false;
  }
}
