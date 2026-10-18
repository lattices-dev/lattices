import { FernRenderer } from './renderer.js';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const state = { effect: 'original', theme: 'dark', intensity: .9, paused: true, content: false };
const treatments = {
  original: { name: 'Illustration', caption: 'Original illustration', note: 'The original silver-and-moss engraving.' },
  ascii: { name: 'ASCII', caption: 'Character field', note: 'Characters follow the light in the same fern.' },
  dither: { name: 'Ordered dither', caption: 'Ordered dither', note: 'A fixed dot pattern resolves light and shade.' },
  etched: { name: 'Engraved lines', caption: 'Engraved lines', note: 'Short strokes trace the original light values.' },
};
const canvas = $('#fern');
const imageStatus = $('#image-status');
let imageReady = false;
$('#export').disabled = true;
canvas.addEventListener('backgroundready', () => { imageReady = true; imageStatus.hidden = true; $('#export').disabled = false; });
canvas.addEventListener('backgrounderror', () => { imageReady = false; imageStatus.hidden = false; imageStatus.textContent = 'The fern could not load. Reload the page to try again.'; $('#export').disabled = true; });
const renderer = new FernRenderer(canvas, state);

const trigger = $('#treatment-trigger');
const menu = $('#treatment-menu');
const options = $$('[data-effect]');
function closeMenu(restoreFocus = false) {
  menu.hidden = true; trigger.setAttribute('aria-expanded', 'false');
  if (restoreFocus) trigger.focus();
}
function openMenu() {
  menu.hidden = false; trigger.setAttribute('aria-expanded', 'true');
  options.find(option => option.dataset.effect === state.effect).focus();
}
trigger.addEventListener('click', () => menu.hidden ? openMenu() : closeMenu());
trigger.addEventListener('keydown', event => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); openMenu(); }
});
menu.addEventListener('keydown', event => {
  const current = options.indexOf(document.activeElement);
  let next = current;
  if (event.key === 'ArrowDown') next = (current + 1) % options.length;
  else if (event.key === 'ArrowUp') next = (current + options.length - 1) % options.length;
  else if (event.key === 'Home') next = 0;
  else if (event.key === 'End') next = options.length - 1;
  else if (event.key === 'Escape') { event.preventDefault(); closeMenu(true); return; }
  else if (event.key === 'Tab') { closeMenu(); trigger.focus(); return; }
  else return;
  event.preventDefault(); options[next].focus();
});
document.addEventListener('pointerdown', event => { if (!event.target.closest('.picker')) closeMenu(); });
options.forEach(option => option.addEventListener('click', async () => {
  state.effect = option.dataset.effect;
  const treatment = treatments[state.effect];
  $('#treatment-name').textContent = treatment.name;
  trigger.setAttribute('aria-label', `Rendering: ${treatment.name}`);
  $('#treatment-caption').textContent = treatment.caption;
  $('#treatment-note').textContent = treatment.note;
  options.forEach(item => item.setAttribute('aria-checked', String(item === option)));
  closeMenu(true);
  await renderer.update(state);
}));

$$('[data-mode]').forEach(button => button.addEventListener('click', () => {
  state.content = button.dataset.mode === 'site';
  $('.page-sample').hidden = !state.content;
  $$('[data-mode]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  renderer.update(state);
}));
$$('button[data-theme]').forEach(button => button.addEventListener('click', () => {
  state.theme = button.dataset.theme;
  document.documentElement.dataset.theme = state.theme;
  $$('button[data-theme]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  renderer.update(state);
}));
$('#presence').addEventListener('input', event => {
  state.intensity = Number(event.target.value) / 100;
  $('#presence-value').value = `${event.target.value}%`;
  renderer.update(state);
});

const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
function syncMotion() {
  const playing = !state.paused && !motionQuery.matches;
  $('#motion').disabled = motionQuery.matches;
  $('#motion').setAttribute('aria-pressed', String(playing));
  $('#motion span').textContent = playing ? 'Pause drift' : 'Play drift';
  $('#motion use').setAttribute('href', playing ? '#pause' : '#play');
  $('#motion-status').textContent = playing ? 'Slow drift' : 'Still frame';
  $('#motion').title = motionQuery.matches ? 'Your reduced-motion preference keeps the artwork still.' : 'A gentle 48-second drift';
}
$('#motion').addEventListener('click', () => { state.paused = !state.paused; syncMotion(); renderer.update(state); });
motionQuery.addEventListener('change', syncMotion);
syncMotion();

$('#export').addEventListener('click', async () => {
  if (!imageReady) return;
  const button = $('#export');
  button.disabled = true;
  const exportCanvas = document.createElement('canvas');
  exportCanvas.style.cssText = 'position:fixed;left:-10000px;top:0;width:1536px;height:1024px;pointer-events:none;';
  document.body.append(exportCanvas);
  const exporter = new FernRenderer(exportCanvas, { ...state, paused: true, content: false });
  try {
    await exporter.update({ ...state, paused: true, content: false });
    const blob = await new Promise(resolve => exportCanvas.toBlob(resolve, 'image/png'));
    if (!blob) throw new Error('Empty image');
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = `lattices-workspace-fern-${state.effect}-${state.theme}.png`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
    $('#action-status').textContent = 'Artwork saved · without page text';
  } catch {
    $('#action-status').textContent = 'Could not save the artwork. Please try again.';
  } finally {
    exporter.destroy(); exportCanvas.remove(); button.disabled = false;
  }
});

const workspaces = {
  research: { name: 'Research', windows: ['Browser', 'Notes', 'Reference'], description: 'Keep the reference close and the next question open.' },
  build: { name: 'Build', windows: ['Editor', 'Terminal', 'Preview', 'Docs'], description: 'Give each part of the build its own place to breathe.' },
  write: { name: 'Write', windows: ['Draft', 'Notes'], description: 'A broad, quiet page with your notes within reach.' },
};
$$('[data-workspace]').forEach(button => button.addEventListener('click', () => {
  const workspace = workspaces[button.dataset.workspace];
  $$('[data-workspace]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  $('#detail-name').textContent = workspace.name;
  $('#detail-count').textContent = `${workspace.windows.length} windows`;
  $('#detail-description').textContent = workspace.description;
  const map = $('#window-map');
  map.dataset.kind = button.dataset.workspace;
  map.replaceChildren(...workspace.windows.map(name => { const item = document.createElement('span'); item.textContent = name; return item; }));
}));
window.addEventListener('pagehide', event => {
  // Back-forward cache restores this instance and its existing controls.
  if (!event.persisted) { renderer.destroy(); motionQuery.removeEventListener('change', syncMotion); }
});
