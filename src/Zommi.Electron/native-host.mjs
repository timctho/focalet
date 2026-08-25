import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

export class NativeHostClient extends EventEmitter {
  constructor(executablePath, options = {}) {
    super();
    this.executablePath = executablePath;
    this.spawnProcess = options.spawnProcess ?? spawn;
    this.process = null;
    this.pending = new Map();
    this.nextId = 0;
    this.stderr = '';
  }

  start() {
    if (this.process) return;
    const child = this.spawnProcess(this.executablePath, ['--electron-host'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });
    this.process = child;
    createInterface({ input: child.stdout }).on('line', (line) => this.#handleLine(line));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      this.stderr = (this.stderr + chunk).slice(-4000);
    });
    child.once('exit', (code) => {
      const detail = this.stderr.trim();
      const message = `Zommi native host exited with code ${code}.${detail ? ` ${detail}` : ''}`;
      for (const { reject } of this.pending.values()) reject(new Error(message));
      this.pending.clear();
      this.process = null;
      this.emit('exit', { code, message });
    });
    child.once('error', (error) => {
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
      this.emit('error', error);
    });
  }

  request(method, params = {}) {
    this.start();
    const id = String(++this.nextId);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.process.stdin.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
        if (!error) return;
        this.pending.delete(id);
        reject(error);
      });
    });
  }

  async stop() {
    if (!this.process) return;
    try {
      await this.request('shutdown');
    } catch {
      // Process teardown below is authoritative.
    }
    if (this.process && !this.process.killed) this.process.kill();
  }

  #handleLine(line) {
    let envelope;
    try {
      envelope = JSON.parse(line);
    } catch {
      this.emit('protocolError', new Error(`Native host emitted invalid JSON: ${line.slice(0, 200)}`));
      return;
    }
    if (envelope.type === 'event') {
      this.emit(envelope.event, envelope.data);
      return;
    }
    if (envelope.type !== 'response' || !envelope.id) return;
    const completion = this.pending.get(String(envelope.id));
    if (!completion) return;
    this.pending.delete(String(envelope.id));
    if (envelope.ok) completion.resolve(envelope.result);
    else completion.reject(new Error(envelope.error || 'Native host request failed.'));
  }
}
