// Loads the real DripCore, compiled to WebAssembly, and wraps its exports.
// `measure(font, scale, text)` gives the drawn width of text in the island's fonts:
// 0 the title (14pt semibold), 1 the detail (12pt regular), 2 the button (12.5pt semibold), times scale.
export async function loadDrip(source, measure) {
  let memory;
  const bytes = () => new Uint8Array(memory.buffer);
  const view = () => new DataView(memory.buffer);
  const decoder = new TextDecoder(), encoder = new TextEncoder();
  const ENOSYS = 52, EBADF = 8, OK = 0;
  let stdout = "";
  // Just enough WASI for Swift's runtime and Foundation to start: no files, no preopened directories.
  const wasi = new Proxy({
    args_sizes_get: (argc, size) => { view().setUint32(argc, 0, true); view().setUint32(size, 0, true); return OK; },
    args_get: () => OK,
    environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return OK; },
    environ_get: () => OK,
    clock_res_get: (id, out) => { view().setBigUint64(out, 1000n, true); return OK; },
    clock_time_get: (id, precision, out) => {
      const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
      view().setBigUint64(out, ns, true); return OK;
    },
    random_get: (pointer, length) => { crypto.getRandomValues(bytes().subarray(pointer, pointer + length)); return OK; },
    fd_write: (fd, iovs, count, written) => {
      let total = 0;
      for (let i = 0; i < count; i++) {
        const base = view().getUint32(iovs + i * 8, true), length = view().getUint32(iovs + i * 8 + 4, true);
        stdout += decoder.decode(bytes().subarray(base, base + length)); total += length;
      }
      view().setUint32(written, total, true);
      const lines = stdout.split("\n"); stdout = lines.pop();
      for (const line of lines) console.log(`[drip fd${fd}]`, line);
      return OK;
    },
    fd_prestat_get: () => EBADF,
    fd_fdstat_get: (fd, out) => fd <= 2 ? (bytes().fill(0, out, out + 24), view().setUint8(out, 2), OK) : EBADF,
    proc_exit: (code) => { throw new Error(`drip exited ${code}`); },
    poll_oneoff: () => ENOSYS,
  }, { get: (target, name) => target[name] ?? (() => ENOSYS) });

  const imports = {
    wasi_snapshot_preview1: wasi,
    drip: {
      measure: (font, scale, pointer, length) => measure(font, scale, decoder.decode(bytes().subarray(pointer, pointer + length))),
    },
  };
  const started = performance.now();
  const { instance } = source instanceof WebAssembly.Module
    ? { instance: await WebAssembly.instantiate(source, imports) }
    : await WebAssembly.instantiate(source, imports);
  const e = instance.exports;
  memory = e.memory;
  e._initialize?.();
  const instantiated = performance.now() - started;

  const readReply = (pointer) => JSON.parse(decoder.decode(bytes().slice(pointer, pointer + e.drip_reply_length())));
  // Hands `object` to `exported` as JSON in the module's memory.
  const pass = (exported, object) => {
    const data = encoder.encode(JSON.stringify(object));
    const pointer = e.drip_alloc(data.length);
    bytes().set(data, pointer);
    try { return exported(pointer, data.length); } finally { e.drip_free(pointer); }
  };
  // One island's frame from `f` at `i`, as `appendFrame` in Bridge.swift lays it out; returns it and
  // where the next value starts.
  const readFrame = (f, i) => {
    const loops = [];
    let j = i + 18;
    for (let n = f[i + 17]; n > 0; n--) { const count = f[j++]; loops.push(f.subarray(j, j + 2 * count)); j += 2 * count; }
    return [{
      pillTop: f[i], pillWidth: f[i + 1], pillHeight: f[i + 2], progress: f[i + 3], blend: f[i + 4], contentWidth: f[i + 5],
      pillRadius: f[i + 6], icon: { x: f[i + 7], y: f[i + 8], size: f[i + 9] }, ring: { x: f[i + 10], y: f[i + 11], size: f[i + 12] },
      textX: f[i + 13], textCenterY: f[i + 14], textRoom: f[i + 15], touchesNotch: f[i + 16] === 1, loops,
    }, j];
  };
  const frameValues = (pointer) => new Float64Array(memory.buffer, pointer, e.drip_frame_length()).slice();
  return {
    instantiated,
    version: readReply(e.drip_version()).version,
    command: (request) => readReply(pass(e.drip_command, request)),
    enter: (handle, time) => readReply(e.drip_enter(handle, time)),
    exit: (handle, time) => readReply(e.drip_exit(handle, time)),
    end: (handle) => e.drip_end(handle),
    open: (handle) => e.drip_open(handle),
    release: (handle) => e.drip_release(handle),
    spring: (duration, bounce, time) => e.drip_spring(duration, bounce, time),
    frame: (handle, time) => readFrame(frameValues(e.drip_frame(handle, time)), 0)[0],
    // Stacks of cards the engine places, times, swaps and sends off as the app's do; `id` is the
    // handle `start` returns, one per notch on the page.
    stack: {
      start: (settings, handles) => pass(e.drip_stack_start, { ...settings, handles }),
      offer: (id, handle) => readReply(e.drip_stack_offer(id, handle)),
      step: (id, time, othersWaiting) => readReply(e.drip_stack_step(id, time, othersWaiting ? 1 : 0)),
      end: (id) => readReply(e.drip_stack_end(id)).handles,
      pointer: (id, x, y, inside, time) => readReply(e.drip_stack_pointer(id, x, y, inside ? 1 : 0, time)),
      click: (id, x, y, time) => readReply(e.drip_stack_click(id, x, y, time)),
      // Takes the card of the island `handle` away, as `drip dismiss` does: "shown" when it goes as
      // cards go, "dropped" when it was still to come and the page releases it, else "".
      dismiss: (id, handle) => ["", "shown", "dropped"][e.drip_stack_dismiss(id, handle)] ?? "",
      // Every card, top to bottom: its island's handle, the seconds left on its countdown, where its
      // capsule's top is heading, how solid its black shape is, and its frame.
      frame(id, time) {
        const f = frameValues(e.drip_stack_frame(id, time));
        const cards = [];
        let i = 1;
        for (let n = f[0]; n > 0; n--) {
          const [frame, next] = readFrame(f, i + 4);
          cards.push({ handle: f[i], remaining: f[i + 1], targetTop: f[i + 2], opacity: f[i + 3], frame });
          i = next;
        }
        return cards;
      },
      // The overflow drop under a full stack, or null: its capsule, and the pieces of the outline it
      // adds, each loops traced where it melts into something, or a plain capsule.
      overflowFrame(id, time) {
        const f = frameValues(e.drip_stack_overflow_frame(id, time));
        if (!f[0]) return null;
        const pieces = [];
        let i = 6;
        for (let n = f[5]; n > 0; n--) {
          if (f[i++] === 1) {
            const loops = [];
            for (let m = f[i++]; m > 0; m--) { const count = f[i++]; loops.push(f.subarray(i, i + 2 * count)); i += 2 * count; }
            pieces.push({ touchesNotch: true, loops });
          } else {
            pieces.push({ touchesNotch: false, pillTop: f[i], pillWidth: f[i + 1], pillHeight: f[i + 2], pillRadius: f[i + 3] });
            i += 4;
          }
        }
        return { pillTop: f[1], pillWidth: f[2], pillHeight: f[3], pillRadius: f[4], pieces };
      },
    },
  };
}
