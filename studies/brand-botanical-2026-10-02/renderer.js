/**
 * Workspace Fern study renderer.
 * Adapted from Scout's design/scout-backgrounds/backgrounds.js on Arts Mini;
 * the source snapshot is in references/scout/components/backgrounds.js.
 * Treatments sample workspace-fern-v1.png. No procedural replacement artwork.
 */

const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
const EFFECTS = new Set(['original', 'ascii', 'dither', 'etched']);
const clamp = value => Math.max(0, Math.min(1, value));
let imagePromise;

function loadFern() {
  if (!imagePromise) {
    imagePromise = new Promise((resolve, reject) => {
      const image = new Image();
      image.decoding = 'async';
      image.onload = () => resolve(image);
      image.onerror = () => {
        imagePromise = undefined;
        reject(new Error('Could not load workspace-fern-v1.png.'));
      };
      image.src = new URL('./workspace-fern-v1.png', import.meta.url).href;
    });
  }
  return imagePromise;
}

/** new FernRenderer(canvas, options); await renderer.update({...}); destroy(). */
export class FernRenderer {
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false });
    if (!this.ctx) throw new Error('This study needs a 2D canvas.');
    this.options = {
      effect: 'original', theme: 'dark', intensity: .9,
      paused: true, content: false,
    };
    this.image = null;
    this.luminances = null;
    this.elapsed = 0;
    this.last = 0;
    this.frame = 0;
    this.visible = true;
    this.destroyed = false;
    this.loading = null;
    this.motion = matchMedia('(prefers-reduced-motion: reduce)');
    this.onVisibility = () => this.sync();
    this.onMotion = () => this.sync();
    document.addEventListener('visibilitychange', this.onVisibility);
    this.motion.addEventListener('change', this.onMotion);
    this.resize = new ResizeObserver(() => {
      this.measure();
      this.draw();
    });
    this.intersection = new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.sync();
    });
    this.resize.observe(canvas);
    this.intersection.observe(canvas);
    this.measure();
    this.ready = this.update(options);
  }

  measure() {
    const bounds = this.canvas.getBoundingClientRect();
    this.w = Math.max(1, Math.round(bounds.width));
    this.h = Math.max(1, Math.round(bounds.height));
    const scale = Math.min(devicePixelRatio || 1, 1.5, 1600 / this.w);
    const width = Math.max(1, Math.round(this.w * scale));
    const height = Math.max(1, Math.round(this.h * scale));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.ctx.setTransform(width / this.w, 0, 0, height / this.h, 0, 0);
  }

  async update(options = {}) {
    if (this.destroyed) return;
    Object.assign(this.options, options);
    if (!EFFECTS.has(this.options.effect)) this.options.effect = 'original';
    this.options.theme = this.options.theme === 'light' ? 'light' : 'dark';
    const intensity = Number(this.options.intensity);
    this.options.intensity = Number.isFinite(intensity) ? clamp(intensity) : .9;
    if (!this.image) {
      if (!this.loading) {
        this.loading = loadFern().then(image => {
          if (this.destroyed) return;
          this.image = image;
          this.sampleImage();
          this.canvas.dispatchEvent(new CustomEvent('backgroundready', {
            detail: { id: 'workspace-fern' },
          }));
        }).catch(error => {
          if (!this.destroyed) {
            this.canvas.dispatchEvent(new CustomEvent('backgrounderror', { detail: error }));
          }
        }).finally(() => { this.loading = null; });
      }
      await this.loading;
    }
    if (!this.destroyed) this.sync();
  }

  sampleImage() {
    const sample = document.createElement('canvas');
    // Retain the image's 3:2 aspect, including its deliberately empty left side.
    this.sampleWidth = Math.min(768, this.image.naturalWidth);
    this.sampleHeight = Math.round(this.sampleWidth * this.image.naturalHeight / this.image.naturalWidth);
    sample.width = this.sampleWidth;
    sample.height = this.sampleHeight;
    const context = sample.getContext('2d', { willReadFrequently: true });
    context.drawImage(this.image, 0, 0, sample.width, sample.height);
    const pixels = context.getImageData(0, 0, sample.width, sample.height).data;
    this.luminances = new Float32Array(sample.width * sample.height);
    for (let i = 0; i < this.luminances.length; i++) {
      const p = i * 4;
      const value = (pixels[p] * .2126 + pixels[p + 1] * .7152 + pixels[p + 2] * .0722) / 255;
      // Remove the charcoal field; the engraving itself determines every mark.
      this.luminances[i] = clamp((value - .055) * 1.7);
    }
  }

  imageBox() {
    const ratio = this.image.naturalWidth / this.image.naturalHeight;
    const width = Math.min(this.w, this.h * ratio);
    const height = width / ratio;
    return { x: this.w - width, y: (this.h - height) / 2, w: width, h: height };
  }

  luminance(x, y, box) {
    const u = (x - box.x) / box.w;
    const v = (y - box.y) / box.h;
    if (u < 0 || u >= 1 || v < 0 || v >= 1) return 0;
    const column = Math.floor(u * this.sampleWidth);
    const row = Math.floor(v * this.sampleHeight);
    return this.luminances[row * this.sampleWidth + column];
  }

  sync() {
    cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.last = 0;
    if (this.destroyed) return;
    this.draw();
    if (this.image && !this.options.paused && !this.motion.matches && !document.hidden && this.visible) {
      this.frame = requestAnimationFrame(now => this.tick(now));
    }
  }

  tick(now) {
    if (this.destroyed) return;
    if (!this.last) this.last = now;
    if (now - this.last >= 1000 / 12) {
      this.elapsed += Math.min((now - this.last) / 1000, .2);
      this.last = now;
      this.draw();
    }
    this.frame = requestAnimationFrame(time => this.tick(time));
  }

  draw() {
    if (this.destroyed) return;
    const { ctx: c, w, h } = this;
    const light = this.options.theme === 'light';
    const background = light ? '#f1f0e9' : '#10120f';
    c.globalAlpha = 1;
    c.globalCompositeOperation = 'source-over';
    c.filter = 'none';
    c.fillStyle = background;
    c.fillRect(0, 0, w, h);
    if (!this.image || !this.luminances) return;
    const intensity = this.options.intensity * (this.options.content ? .34 : 1);
    const phase = this.elapsed / 48 * Math.PI * 2;
    const box = this.imageBox();

    if (this.options.effect === 'original') {
      c.globalAlpha = intensity;
      c.imageSmoothingEnabled = true;
      c.imageSmoothingQuality = 'high';
      // The dark treatment retains the original pixels and fine silver detail.
      // Multiply places the inverted drawing on the warm paper in light mode.
      c.filter = light ? 'grayscale(1) invert(1)' : 'none';
      c.globalCompositeOperation = light ? 'multiply' : 'source-over';
      c.drawImage(this.image, box.x + Math.sin(phase) * w * .003, box.y, box.w, box.h);
      c.filter = 'none';
      c.globalCompositeOperation = 'source-over';
      c.globalAlpha = 1;
      this.feather(box, light);
      return;
    }

    c.fillStyle = light ? '#424a3b' : '#d2d0bf';
    const effect = this.options.effect;
    const step = effect === 'ascii' ? (w < 500 ? 7 : 8) : effect === 'dither' ? 2.5 : 4;
    const yStep = effect === 'ascii' ? step * 1.3 : step;
    c.font = `${step}px ui-monospace, SFMono-Regular, Menlo, monospace`;
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    const ramp = ' .,:;+=*#%@';
    const breathing = .985 + Math.sin(phase) * .015;
    for (let row = 0, y = yStep / 2; y < h; row++, y += yStep) {
      for (let column = 0, x = step / 2; x < w; column++, x += step) {
        const value = this.luminance(x, y, box) * breathing;
        if (value < .025) continue;
        if (effect === 'ascii') {
          c.globalAlpha = intensity * (.25 + value * .75);
          c.fillText(ramp[Math.min(ramp.length - 1, Math.floor(value * ramp.length))], x, y);
        } else if (effect === 'dither') {
          const threshold = (BAYER[(row % 4) * 4 + column % 4] + .5) / 16;
          if (value > threshold) {
            c.globalAlpha = intensity * .9;
            c.fillRect(x - .75, y - .75, 1.5, 1.5);
          }
        } else {
          c.globalAlpha = intensity * value;
          c.fillRect(x, y, .8 + value * 3.2, .75);
        }
      }
    }
    c.globalAlpha = 1;
  }

  feather(box, light) {
    const c = this.ctx;
    const rgb = light ? '241,240,233' : '16,18,15';
    if (box.x > 0) {
      const width = Math.min(32, box.w * .08);
      const fade = c.createLinearGradient(box.x, 0, box.x + width, 0);
      fade.addColorStop(0, `rgba(${rgb},1)`);
      fade.addColorStop(1, `rgba(${rgb},0)`);
      c.fillStyle = fade;
      c.fillRect(box.x, 0, width, this.h);
    }
    if (box.y > 0) {
      const feather = Math.min(24, box.h * .08);
      const top = c.createLinearGradient(0, box.y, 0, box.y + feather);
      top.addColorStop(0, `rgba(${rgb},1)`);
      top.addColorStop(1, `rgba(${rgb},0)`);
      c.fillStyle = top;
      c.fillRect(0, box.y, this.w, feather);
      const bottom = c.createLinearGradient(0, box.y + box.h - feather, 0, box.y + box.h);
      bottom.addColorStop(0, `rgba(${rgb},0)`);
      bottom.addColorStop(1, `rgba(${rgb},1)`);
      c.fillStyle = bottom;
      c.fillRect(0, box.y + box.h - feather, this.w, feather);
    }
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    cancelAnimationFrame(this.frame);
    this.resize.disconnect();
    this.intersection.disconnect();
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.motion.removeEventListener('change', this.onMotion);
  }
}
