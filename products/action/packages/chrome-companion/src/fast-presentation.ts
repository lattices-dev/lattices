/** Live executor feedback, excluded from observation and hit testing. */
export type FastPresentationPrefs = { sound?: boolean; volume?: number };

export function createFastPresentation(doc: Document) {
  const win = doc.defaultView!;
  let host: HTMLElement | undefined, root: ShadowRoot, pointer: HTMLElement, outline: HTMLElement, label: HTMLElement;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let position = { x: 80, y: 150 };
  let prefs: Required<FastPresentationPrefs> = { sound: true, volume: 0.35 };
  let audio: AudioContext | undefined;

  const reduced = () => win.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function mount() {
    if (host?.isConnected) return;
    host = doc.createElement('div');
    host.setAttribute('aria-hidden', 'true');
    host.dataset.actionPresentation = 'true';
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
    root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      :host{pointer-events:none}*{box-sizing:border-box;pointer-events:none}
      .pointer{position:absolute;left:0;top:0;filter:drop-shadow(0 3px 5px #0005)}
      .disc{width:26px;height:26px;border-radius:50%;background:#ef6a47;border:3px solid #fff;
        box-shadow:0 0 0 7px #ef6a4726,0 0 14px #ef6a474d}
      .label{position:absolute;left:22px;top:34px;background:#0e1213;color:#f3ebdd;padding:5px 9px;border-radius:7px;font:600 12px/1.3 system-ui;white-space:nowrap;max-width:330px;overflow:hidden;text-overflow:ellipsis}
      .outline{position:absolute;border:1.5px solid #ef6a47;border-radius:8px;background:#ef6a470a}
      .bubble{position:absolute;border-radius:50%;border:2px solid #ef6a47;transform:translate(-50%,-50%)}
    </style><div class="outline"></div><div class="pointer"><div class="disc"></div><span class="label"></span></div>`;
    pointer = root.querySelector('.pointer')!; outline = root.querySelector('.outline')!; label = root.querySelector('.label')!;
    pointer.style.transform = `translate(${position.x - 13}px,${position.y - 13}px)`;
    doc.documentElement.append(host);
  }

  function bubble(x: number, y: number, delay: number, size: number) {
    const ring = doc.createElement('div');
    ring.className = 'bubble';
    root.append(ring);
    ring.style.left = `${x}px`; ring.style.top = `${y}px`;
    ring.animate(
      [{ width: '10px', height: '10px', opacity: 0.75 }, { width: `${size}px`, height: `${size}px`, opacity: 0 }],
      { duration: 480, delay, easing: 'cubic-bezier(.16,.8,.3,1)' },
    ).finished.finally(() => ring.remove());
  }

  function tick(index: number) {
    if (!prefs.sound || prefs.volume <= 0) return;
    try {
      audio ??= new win.AudioContext();
      if (audio.state === 'suspended') void audio.resume();
      const osc = audio.createOscillator();
      const gain = audio.createGain();
      const now = audio.currentTime;
      osc.type = 'triangle';
      osc.frequency.value = 1900 + (index % 4) * 140;
      gain.gain.setValueAtTime(Math.min(0.5, prefs.volume) * 0.14, now);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.035);
      osc.connect(gain).connect(audio.destination);
      osc.start(now); osc.stop(now + 0.04);
    } catch {
      // Audio is best-effort feedback; never block input on it.
    }
  }

  return {
    configure(next: FastPresentationPrefs) {
      if (typeof next.sound === 'boolean') prefs.sound = next.sound;
      if (typeof next.volume === 'number' && Number.isFinite(next.volume)) {
        prefs.volume = Math.min(1, Math.max(0, next.volume));
      }
    },
    async target(element: HTMLElement, operation: string, name: string) {
      mount(); clearTimeout(timer);
      const r = element.getBoundingClientRect();
      const next = { x: r.x + r.width / 2, y: r.y + r.height / 2 };
      label.textContent = `Action · ${operation === 'CLICK' ? 'Click' : 'Type'} · ${name || 'control'}`;
      label.style.left = next.x > win.innerWidth - 350 ? '-300px' : '22px';
      label.style.top = next.y > win.innerHeight - 80 ? '-44px' : '34px';
      outline.style.cssText = `left:${r.x - 3}px;top:${r.y - 3}px;width:${r.width + 6}px;height:${r.height + 6}px`;
      const distance = Math.hypot(next.x - position.x, next.y - position.y);
      const duration = Math.min(190, 90 + distance * 0.11);
      // A shallow quadratic arc preserves direction without a mechanical straight slide.
      const bend = Math.min(18, distance * 0.045);
      const dx = next.x - position.x, dy = next.y - position.y;
      const control = { x: (position.x + next.x) / 2 - dy / Math.max(distance, 1) * bend,
        y: (position.y + next.y) / 2 + dx / Math.max(distance, 1) * bend };
      const frames = Array.from({ length: 9 }, (_, i) => {
        const t = i / 8, u = 1 - t;
        const x = u * u * position.x + 2 * u * t * control.x + t * t * next.x;
        const y = u * u * position.y + 2 * u * t * control.y + t * t * next.y;
        return { transform: `translate(${x - 13}px,${y - 13}px)`, offset: t };
      });
      if (!reduced()) {
        const travel = pointer.animate(frames, { duration, easing: 'cubic-bezier(.2,.7,.15,1)', fill: 'forwards' });
        await travel.finished;
      }
      pointer.style.transform = `translate(${next.x - 13}px,${next.y - 13}px)`;
      pointer.getAnimations().forEach(a => a.cancel()); position = next;
      await new Promise(resolve => setTimeout(resolve, 55));
    },
    pulse() {
      mount();
      // Click bubbles bloom from the confirmed point of input.
      if (!reduced()) {
        bubble(position.x, position.y, 0, 52);
        bubble(position.x, position.y, 70, 30);
        pointer.querySelector('.disc')!.animate([
          { transform: 'scale(1)' }, { transform: 'scale(.72)', offset: .3 }, { transform: 'scale(1)' },
        ], { duration: 150, easing: 'ease-out' });
      }
      outline.animate([{ backgroundColor: '#ef6a4730' }, { backgroundColor: '#ef6a470a' }], { duration: 200 });
    },
    keystroke(index: number) {
      tick(index);
      if (!reduced()) outline.animate(
        [{ borderColor: '#ef6a47' }, { borderColor: '#ff9d85' }, { borderColor: '#ef6a47' }],
        { duration: 90 },
      );
    },
    finish(message: string) {
      if (label) label.textContent = `Action · ${message}`;
      timer = setTimeout(() => { host?.remove(); host = undefined; }, 850);
    },
  };
}
