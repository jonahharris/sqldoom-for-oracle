// The page's (and the Node tools') connection to doom_web.py, the Oracle bridge. The counterpart of
// CedarDB SQLDoom's pgwire.js: where that one speaks the Postgres protocol through a byte tunnel,
// this one speaks the bridge's small protocol -- sign in as your own player account, run named
// api_* statements, ask for frames. No SQL text ever leaves the page.
//
//   const db = new OraConnection('ws://host:8080/ws');
//   await db.connect({ user, password });          // or { guest: true }
//   const [join, score] = await db.run([{ name: 'join' }, { name: 'score' }]);   // {value} / {rows}
//   const f = await db.frame({ alpha: 0.5 });     // {kind: 'view'|'automap'|null, pal, indices: Uint8Array(64000)}
export class OraConnection {
  constructor(url) {
    this.url = url;
    this.ws = null;
    this.user = null;
    this.nextId = 1;
    this.pending = new Map();
    this.prev = new Map();        // the last decoded frame of each kind, for the XOR delta
    this.onclose = null;
    this.bytesIn = 0;
  }

  connect(login) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      ws.binaryType = 'arraybuffer';
      this.ws = ws;
      let signedIn = false;
      ws.onopen = () => ws.send(JSON.stringify({ op: 'login', ...login }));
      ws.onerror = () => { if (!signedIn) reject(new Error('cannot reach the bridge')); };
      ws.onclose = (ev) => {
        const err = new Error(ev.reason || `connection closed (${ev.code})`);
        for (const [, p] of this.pending) p.reject(err);
        this.pending.clear();
        if (!signedIn) reject(err);
        else if (this.onclose) this.onclose(err);
      };
      ws.onmessage = (ev) => {
        if (typeof ev.data === 'string') {
          const m = JSON.parse(ev.data);
          this.bytesIn += ev.data.length;
          if (m.op === 'login') {
            if (m.ok) { signedIn = true; this.user = m.user; resolve(this); } else reject(new Error(m.error));
            return;
          }
          const p = this.pending.get(m.id);
          if (!p) return;
          this.pending.delete(m.id);
          if (m.error) p.reject(new Error(m.error)); else p.resolve(m.results);
          return;
        }
        const buf = new Uint8Array(ev.data);
        this.bytesIn += buf.length;
        const view = new DataView(ev.data);
        const id = view.getUint32(0, true), kind = buf[4], pal = buf[5], delta = buf[6];
        const p = this.pending.get(id);
        if (!p) return;
        this.pending.delete(id);
        if (kind === 255) { p.resolve({ kind: null, pal: 0, indices: null }); return; }
        let indices = buf.slice(7);
        if (delta) {
          const prev = this.prev.get(kind);
          if (prev && prev.length === indices.length) for (let i = 0; i < indices.length; i++) indices[i] ^= prev[i];
        }
        this.prev.set(kind, indices);
        p.resolve({ kind: kind === 1 ? 'automap' : 'view', pal, indices });
      };
    });
  }

  _send(msg) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, ...msg }));
    });
  }

  // A batch of named statements, answered in order. Each result is {rows} or {value}; a failed
  // statement rejects the batch with its message.
  async run(batch) {
    const results = await this._send({ run: batch });
    for (const r of results) if (r.error) { const e = new Error(r.error); throw e; }
    return results;
  }

  frame(req) { return this._send({ frame: req }); }

  close() { try { this.ws.close(); } catch (e) { /* already closed */ } }
}

// base64 cells (BLOBs) -> Uint8Array
export function bytes(cell) {
  if (!cell || !cell.b64) return null;
  if (typeof Buffer !== 'undefined') return new Uint8Array(Buffer.from(cell.b64, 'base64'));
  const s = atob(cell.b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
