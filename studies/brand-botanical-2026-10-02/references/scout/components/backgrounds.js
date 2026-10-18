/** Scout decorative backgrounds. No dependencies, network access, or app state. */
export const backgrounds = [
  { id: 'listening-station', name: 'Listening station', kind: 'illustration', use: 'Home · welcome', description: 'A quiet receiver above an etched landscape. A little sense of discovery, with room for a greeting.', motion: '48-second breathing drift', file: 'assets/listening-station.png' },
  { id: 'relay-islands', name: 'Relay islands', kind: 'illustration', use: 'Mesh · connections', description: 'Separate places, connected by fine threads. An illustration of reachability, without turning the page into a network diagram.', motion: '48-second breathing drift', file: 'assets/relay-islands.png' },
  { id: 'signal-grove', name: 'Signal grove', kind: 'illustration', use: 'Agents · discovery', description: 'An instrument garden: many small listeners, each with its own silhouette. Detail gathers away from the reading area.', motion: '48-second breathing drift', file: 'assets/signal-grove.png' },
  { id: 'scout-at-rest', name: 'Scout at rest', kind: 'illustration', use: 'Empty states · all caught up', description: 'The headphone-wearing Scout dog, curled up at the edge of the page. A companion for the quiet moments.', motion: '48-second breathing drift', file: 'assets/scout-at-rest.png' },
  { id: 'ascii-terrain', name: 'ASCII terrain', kind: 'digital', use: 'Projects · workspace', description: 'A landscape made from punctuation. Characters hold their place while a slow field passes beneath them.', motion: '40-second seamless cycle', effect: 'ascii' },
  { id: 'dither-tide', name: 'Dither tide', kind: 'digital', use: 'Home · overview', description: 'Ordered pixels resolve into soft, overlapping light. The texture moves as a coherent field, with no random static.', motion: '40-second seamless cycle', effect: 'dither' },
  { id: 'contour-drift', name: 'Contour drift', kind: 'digital', use: 'Search · knowledge', description: 'Fine topographic lines trace a slowly changing landscape. The quietest option for screens with more text.', motion: '40-second seamless cycle', effect: 'contour' },
  { id: 'halftone-orbit', name: 'Halftone orbit', kind: 'digital', use: 'Activity · overview', description: 'A field of small print-like dots follows a broad orbital form. Soft depth, without a glow or a spotlight.', motion: '40-second seamless cycle', effect: 'halftone' },
  {"id":"relay-archipelago","name":"Relay archipelago","family":"Relay islands","series":2,"kind":"illustration","use":"Mesh · distant connections","description":"A constellation of small outposts, strung together across a generous dark expanse. A map of places you could reach.","motion":"48-second breathing drift","file":"assets/relay-archipelago.png"},
  {"id":"hanging-observatory","name":"Hanging observatory","family":"Relay islands","series":2,"kind":"illustration","use":"Home · perspective","description":"One solitary world with a ring suspended above its fractured stone. An outpost at the edge of the known.","motion":"48-second breathing drift","file":"assets/hanging-observatory.png"},
  {"id":"bridge-of-whispers","name":"Bridge of whispers","family":"Relay islands","series":2,"kind":"illustration","use":"Connections · handoffs","description":"Two distant islands joined by a barely-there crossing. Small instruments make the scale feel enormous.","motion":"48-second breathing drift","file":"assets/bridge-of-whispers.png"},
  {"id":"listening-canopy","name":"Listening canopy","family":"Signal grove","series":2,"kind":"illustration","use":"Agents · shared attention","description":"A grove of instruments that branches into a delicate canopy. Many listeners, one quiet place.","motion":"48-second breathing drift","file":"assets/listening-canopy.png"},
  {"id":"resonance-grove","name":"Resonance grove","family":"Signal grove","series":2,"kind":"illustration","use":"Activity · rhythm","description":"Fine tuning forks and open loops gather on a crescent of stone. A landscape that almost feels audible.","motion":"48-second breathing drift","file":"assets/resonance-grove.png"},
  {"id":"seed-library","name":"Seed library","family":"Signal grove","series":2,"kind":"illustration","use":"Knowledge · possibilities","description":"Small ideas held in instrument pods, waiting to unfold. A more curious, organic corner of the Scout world.","motion":"48-second breathing drift","file":"assets/seed-library.png"},
  {"id":"quiet-harbor","name":"Quiet harbor","family":"Relay islands","series":3,"kind":"illustration","use":"Home · arrival","description":"A crescent of basalt shelters three little outposts, held by fine mooring lines. Somewhere for a thought to arrive.","motion":"48-second breathing drift","file":"assets/quiet-harbor.png"},
  {"id":"terrace-of-echoes","name":"Terrace of echoes","family":"Relay islands","series":3,"kind":"illustration","use":"Projects · layers of work","description":"A long path winds around a terraced island toward one small receiver. Each layer holds the trace of the last.","motion":"48-second breathing drift","file":"assets/terrace-of-echoes.png"},
  {"id":"suspended-archive","name":"Suspended archive","family":"Relay islands","series":3,"kind":"illustration","use":"Knowledge · accumulated context","description":"Four stone layers hover apart, joined by fine vertical threads. An archive you can read through its gaps.","motion":"48-second breathing drift","file":"assets/suspended-archive.png"},
  {"id":"fiddlehead-array","name":"Fiddlehead array","family":"Signal grove","series":3,"kind":"illustration","use":"Discovery · unfolding ideas","description":"Fine spiral receivers slowly unfurl above the stone. An instrument garden caught between structure and growth.","motion":"48-second breathing drift","file":"assets/fiddlehead-array.png"},
  {"id":"prism-orchard","name":"Prism orchard","family":"Signal grove","series":3,"kind":"illustration","use":"Agents · different perspectives","description":"Faceted prisms hang from an open branching frame. Each catches the same quiet signal from a different angle.","motion":"48-second breathing drift","file":"assets/prism-orchard.png"},
  {"id":"rain-garden","name":"Rain garden","family":"Signal grove","series":3,"kind":"illustration","use":"Activity · quiet attention","description":"A fine canopy gathers a rain of suspended beads over a shallow stone bowl. The stillness after a busy stretch.","motion":"48-second breathing drift","file":"assets/rain-garden.png"},
];

const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const smooth = (a, b, x) => { const u = clamp((x - a) / (b - a)); return u * u * (3 - 2 * u); };
const images = new Map();
function getImage(file) {
  if (!images.has(file)) images.set(file, new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => { images.delete(file); reject(new Error(`Could not load ${file}`)); };
    image.src = new URL(file, import.meta.url).href;
  }));
  return images.get(file);
}

/** Reusable host: new ScoutBackground(canvas, options); update({...}); destroy(). */
export class ScoutBackground {
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false });
    this.options = { id: 'ascii-terrain', theme: 'dark', intensity: 0.65, paused: false, effect: 'original', content: false, ...options };
    this.motion = matchMedia('(prefers-reduced-motion: reduce)');
    this.visible = true;
    this.elapsed = 0;
    this.last = 0;
    this.frame = 0;
    this.destroyed = false;
    this.sample = document.createElement('canvas');
    this.sample.width = 240; this.sample.height = 150;
    this.sampleCtx = this.sample.getContext('2d', { willReadFrequently: true });
    this.onVisibility = () => this.sync();
    this.onMotion = () => this.sync();
    document.addEventListener('visibilitychange', this.onVisibility);
    this.motion.addEventListener('change', this.onMotion);
    this.resize = new ResizeObserver(() => { this.measure(); this.draw(); });
    this.resize.observe(canvas);
    this.intersection = new IntersectionObserver(([entry]) => { this.visible = entry.isIntersecting; this.sync(); });
    this.intersection.observe(canvas);
    this.measure();
    this.update(options);
  }
  measure() {
    const { width, height } = this.canvas.getBoundingClientRect();
    this.w = Math.max(1, Math.round(width)); this.h = Math.max(1, Math.round(height));
    // Cap the backing store for wide monitors and high-density displays.
    const scale = Math.min(devicePixelRatio || 1, 1.5, 1600 / this.w);
    this.canvas.width = Math.round(this.w * scale); this.canvas.height = Math.round(this.h * scale);
    this.ctx.setTransform(scale, 0, 0, scale, 0, 0);
  }
  async update(options) {
    const oldId = this.options.id;
    Object.assign(this.options, options);
    this.options.intensity = clamp(this.options.intensity);
    this.item = backgrounds.find(b => b.id === this.options.id) || backgrounds[4];
    if (oldId !== this.options.id) { this.image = null; this.pixels = null; }
    const id = this.item.id;
    if (this.item.file && !this.image) {
      try {
        const image = await getImage(this.item.file);
        if (this.destroyed || id !== this.item.id) return;
        this.image = image;
        this.sampleCtx.drawImage(image, 0, 0, this.sample.width, this.sample.height);
        this.pixels = this.sampleCtx.getImageData(0, 0, this.sample.width, this.sample.height).data;
        this.canvas.dispatchEvent(new CustomEvent('backgroundready', { detail: { id } }));
      } catch (error) {
        if (!this.destroyed && id === this.item.id) this.canvas.dispatchEvent(new CustomEvent('backgrounderror', { detail: error }));
      }
    }
    if (!this.destroyed) { this.draw(); this.sync(); }
  }
  sync() {
    cancelAnimationFrame(this.frame); this.frame = 0; this.last = 0;
    if (this.destroyed) return;
    this.draw();
    if (!this.options.paused && !this.motion.matches && !document.hidden && this.visible) this.frame = requestAnimationFrame(t => this.tick(t));
  }
  tick(now) {
    if (!this.last) this.last = now;
    if (now - this.last >= 1000 / 12) {
      this.elapsed += Math.min((now - this.last) / 1000, 0.2);
      this.last = now; this.draw();
    }
    this.frame = requestAnimationFrame(t => this.tick(t));
  }
  field(x, y, phase) {
    const u = x / this.w, v = y / this.h;
    const aspect = this.w / this.h;
    // Both components complete exactly one cycle. No temporal random noise.
    const cx = 0.72 + 0.028 * Math.sin(phase), cy = 0.51 + 0.035 * Math.cos(phase);
    const dx = (u - cx) * aspect, dy = v - cy;
    const r = Math.hypot(dx, dy);
    const wave = Math.sin(u * 8 + Math.cos(phase) * 0.3 + Math.sin(v * 5) * 2);
    const falloff = smooth(0.08, 0.52, u) * (1 - smooth(0.65, 1.2, r));
    if (this.item.id === 'halftone-orbit') return clamp((0.52 + 0.4 * Math.sin(r * 13 + wave * 0.35 + Math.sin(phase) * 0.4)) * falloff);
    return clamp((0.42 + wave * 0.23 + Math.cos(v * 9 + u * 3 + Math.sin(phase) * 0.6) * 0.22) * falloff);
  }
  imageBox() {
    const ratio = this.image.width / this.image.height;
    // Preserve tall antennae and the mascot at every aspect ratio, anchored right.
    const dw = Math.min(this.w, this.h * ratio);
    const dh = dw / ratio;
    return { x: this.w - dw, y: (this.h - dh) / 2, w: dw, h: dh };
  }
  luminance(x, y, phase) {
    if (!this.pixels) return this.field(x, y, phase);
    const box = this.imageBox();
    const u = (x - box.x) / box.w, v = (y - box.y) / box.h;
    if (u < 0 || u > 1 || v < 0 || v > 1) return 0;
    const i = (Math.min(149, Math.floor(v * 150)) * 240 + Math.min(239, Math.floor(u * 240))) * 4;
    const l = (this.pixels[i] * .2126 + this.pixels[i + 1] * .7152 + this.pixels[i + 2] * .0722) / 255;
    return clamp((l - 0.045) * 1.7) * (0.97 + Math.sin(phase) * 0.03);
  }
  draw() {
    if (!this.ctx || !this.item) return;
    const { ctx: c, w, h } = this;
    const light = this.options.theme === 'light';
    c.globalAlpha = 1; c.filter = 'none';
    c.fillStyle = light ? '#f5f4ef' : '#101210'; c.fillRect(0, 0, w, h);
    const intensity = this.options.intensity * (this.options.content ? 0.34 : 1);
    const phase = this.elapsed / 40 * Math.PI * 2;
    const effect = this.item.kind === 'digital' ? this.item.effect : this.options.effect;
    if (this.item.kind === 'illustration' && !this.image) return;
    if (this.image && effect === 'original') {
      const box = this.imageBox();
      const offset = Math.sin(this.elapsed / 48 * Math.PI * 2) * w * .003;
      c.globalAlpha = intensity;
      c.filter = light ? 'grayscale(1) invert(1)' : 'none';
      c.drawImage(this.image, box.x + offset, box.y, box.w, box.h);
      c.filter = 'none'; c.globalAlpha = 1;
      if (box.x > 0) {
        const rgb = light ? '245,244,239' : '16,18,16';
        const fade = c.createLinearGradient(0, 0, box.x + 32, 0);
        fade.addColorStop(0, `rgba(${rgb},1)`);
        fade.addColorStop(box.x / (box.x + 32), `rgba(${rgb},1)`);
        fade.addColorStop(1, `rgba(${rgb},0)`);
        c.fillStyle = fade; c.fillRect(0, 0, box.x + 32, h);
      }
      if (box.y > 0) {
        const rgb = light ? '245,244,239' : '16,18,16';
        const feather = Math.min(32, box.h * .12);
        const top = c.createLinearGradient(0, box.y, 0, box.y + feather);
        top.addColorStop(0, `rgba(${rgb},1)`); top.addColorStop(1, `rgba(${rgb},0)`);
        c.fillStyle = top; c.fillRect(0, box.y, w, feather);
        const bottom = c.createLinearGradient(0, box.y + box.h - feather, 0, box.y + box.h);
        bottom.addColorStop(0, `rgba(${rgb},0)`); bottom.addColorStop(1, `rgba(${rgb},1)`);
        c.fillStyle = bottom; c.fillRect(0, box.y + box.h - feather, w, feather);
      }
      return;
    }
    c.fillStyle = light ? '#4e5545' : '#c7cec0';
    c.strokeStyle = c.fillStyle;
    if (effect === 'contour') {
      c.lineWidth = .75;
      for (let row = -6; row < 47; row++) {
        c.beginPath();
        for (let x = -4; x <= w + 4; x += 4) {
          const u = x / w;
          const envelope = Math.exp(-Math.pow((u - .7) * 3, 2));
          const y = row * h / 38 + Math.sin(u * 10 + row * .1 + Math.sin(phase) * .25) * h * .14 * envelope;
          x === -4 ? c.moveTo(x, y) : c.lineTo(x, y);
        }
        c.globalAlpha = intensity * (.14 + .35 * Math.sin((row + 7) / 54 * Math.PI)); c.stroke();
      }
    } else {
      const step = effect === 'ascii' ? (w < 500 ? 8 : 10) : effect === 'dither' ? 3 : effect === 'etched' ? 5 : 9;
      const yStep = effect === 'ascii' ? step * 1.3 : step;
      c.font = `${step}px ui-monospace, SFMono-Regular, Menlo, monospace`;
      c.textAlign = 'center'; c.textBaseline = 'middle';
      const ramp = ' .·:+*#%@';
      for (let y = step / 2; y < h; y += yStep) for (let x = step / 2; x < w; x += step) {
        const l = this.luminance(x, y, phase);
        if (l < .025) continue;
        if (effect === 'ascii') {
          c.globalAlpha = intensity * (.15 + l * .75);
          c.fillText(ramp[Math.min(ramp.length - 1, Math.floor(l * ramp.length))], x, y);
        } else if (effect === 'dither') {
          const threshold = (bayer[(Math.floor(y / step) % 4) * 4 + Math.floor(x / step) % 4] + .5) / 16;
          if (l > threshold) { c.globalAlpha = intensity * .7; c.fillRect(x, y, 1.5, 1.5); }
        } else if (effect === 'etched') {
          c.globalAlpha = intensity * l;
          c.fillRect(x, y, .8 + l * 4, .7);
        } else {
          c.globalAlpha = intensity * .75;
          c.beginPath(); c.arc(x, y, Math.max(.25, Math.sqrt(l) * 2.6), 0, Math.PI * 2); c.fill();
        }
      }
    }
    // Edge falloff gives the content side and perimeter a calm resting field.
    c.globalAlpha = 1;
    const fade = c.createLinearGradient(0, 0, w, 0);
    const rgb = light ? '245,244,239' : '16,18,16';
    fade.addColorStop(0, `rgba(${rgb},.94)`); fade.addColorStop(.28, `rgba(${rgb},.5)`); fade.addColorStop(.64, `rgba(${rgb},0)`);
    c.fillStyle = fade; c.fillRect(0, 0, w, h);
  }
  destroy() {
    this.destroyed = true; cancelAnimationFrame(this.frame);
    this.resize.disconnect(); this.intersection.disconnect();
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.motion.removeEventListener('change', this.onMotion);
  }
}
