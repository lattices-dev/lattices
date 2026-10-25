/* Input study only. The native app owns system event routing. */
(() => {
  const THRESHOLD = 44;
  const qualifies = (dx, dy) => -dy >= THRESHOLD && -dy > Math.abs(dx) * 1.25;
  if (typeof module !== 'undefined') module.exports = { qualifies, THRESHOLD };
  if (typeof window === 'undefined') return;

  window.installApertureGesture = ({ stage, getState, openCanvas }) => {
    if (stage.dataset.gestureInstalled) return;
    stage.dataset.gestureInstalled = 'true';
    const style = document.createElement('style');
    style.textContent = `
      .gesture-bar {display:flex;flex-wrap:wrap;gap:8px 20px;align-items:center;margin:12px 0;color:#d2dadd;font-size:13px;line-height:1.5}
      .gesture-bar strong {color:#f3eee0;font-weight:550}
      .gesture-bar button {font:inherit;padding:5px 10px}
      .gesture-bar .gesture-status {color:#b7c7ce}
      .gesture-anchor {position:absolute;width:40px;height:72px;margin-left:-20px;margin-top:-58px;z-index:30;pointer-events:none;opacity:0;color:#f3eee0}
      .gesture-anchor.visible {opacity:1}
      .gesture-anchor svg {width:40px;height:72px;overflow:visible;filter:drop-shadow(0 3px 5px #0008)}
      .gesture-anchor .stem {stroke:#e8e5d8;stroke-width:1.5}
      .gesture-anchor .track {stroke:#e8e5d850;stroke-width:1;stroke-dasharray:2 3}
      .gesture-anchor .pull {stroke:#f3eee0;stroke-width:2;stroke-dasharray:44;stroke-dashoffset:44}
      .gesture-anchor .handle {fill:#15242c;stroke:#f3eee0;stroke-width:1.5}
      .gesture-anchor.recognized .handle {fill:#f3eee0}
      #stage[data-gesture-state="pulling"] {cursor:ns-resize}
      .gesture-footnote {margin:8px 0 16px;font-size:12px;color:#aebdc5;max-width:90ch}
    `;
    document.head.appendChild(style);
    const bar = document.createElement('div');
    bar.className = 'gesture-bar';
    bar.innerHTML = '<strong>Hold right-click + pull up</strong><span>Ctrl + Option + scroll to zoom</span><button type="button">Open canvas</button><span class="gesture-status" role="status" aria-live="polite">Release to keep browsing. Double-click or Enter to land.</span>';
    stage.before(bar);
    const status = bar.querySelector('.gesture-status');
    const note = document.createElement('p'); note.className = 'gesture-footnote';
    note.textContent = 'Gesture study · inside this preview, the right button is reserved for pulling. Ordinary clicks outside the preview keep their normal behavior.';
    stage.after(note);
    const anchor = document.createElement('div'); anchor.className = 'gesture-anchor'; anchor.setAttribute('aria-hidden','true');
    anchor.innerHTML = '<svg viewBox="0 0 40 72"><path class="track" d="M20 58V14"/><path class="pull" d="M20 58V14"/><path class="stem" fill="none" d="m14 20 6-6 6 6"/><rect class="handle" x="16" y="54" width="8" height="8" rx="2"/></svg>';
    stage.appendChild(anchor);
    const pull = anchor.querySelector('.pull');
    let tracking = null, wheelTotal = 0, wheelAt = 0, wheelOpeningUntil = 0;
    const report = text => { if (status.textContent !== text) status.textContent = text; };
    const open = () => {
      if (getState().zoom < 1.98) openCanvas();
      stage.dataset.gestureState = 'open';
      report('Canvas open · release to browse. Double-click or Enter to land.');
      stage.focus({preventScroll:true});
    };
    bar.querySelector('button').addEventListener('click', open);
    const finish = () => {
      if (!tracking) return;
      const {opened:wasOpen,id} = tracking;
      tracking = null;
      if (stage.hasPointerCapture(id)) stage.releasePointerCapture(id);
      anchor.classList.remove('visible', 'recognized');
      stage.dataset.gestureState = wasOpen ? 'open' : 'idle';
      report(wasOpen ? 'Canvas stays open · click to select, double-click or Enter to land.' : 'Pull up a little farther to open the canvas.');
    };
    stage.addEventListener('pointerdown', e => {
      if (e.button !== 2 || getState().zoom >= 1.98) return;
      e.preventDefault(); e.stopImmediatePropagation();
      const bounds = stage.getBoundingClientRect();
      tracking = {id:e.pointerId,x:e.clientX,y:e.clientY,opened:false};
      stage.setPointerCapture(e.pointerId); stage.focus({preventScroll:true});
      stage.dataset.gestureState = 'pulling';
      anchor.style.left = Math.max(22, Math.min(bounds.width-22,e.clientX-bounds.left))+'px';
      anchor.style.top = Math.max(62,e.clientY-bounds.top)+'px';
      pull.style.strokeDashoffset = '44'; anchor.classList.add('visible');
      report('Pull up to open the canvas. Release early to cancel.');
    }, true);
    stage.addEventListener('pointermove', e => {
      if (!tracking || e.pointerId !== tracking.id) return;
      e.preventDefault(); e.stopImmediatePropagation();
      if (!(e.buttons & 2)) { finish(); return; }
      if (tracking.opened) return;
      const dx = e.clientX-tracking.x, dy = e.clientY-tracking.y;
      pull.style.strokeDashoffset = String(THRESHOLD-Math.max(0,Math.min(THRESHOLD,-dy)));
      if (qualifies(dx,dy)) {tracking.opened=true; anchor.classList.add('recognized'); open();}
    }, true);
    stage.addEventListener('pointerup', e => {
      if (!tracking || e.pointerId !== tracking.id) return;
      e.preventDefault(); e.stopImmediatePropagation(); finish();
    }, true);
    stage.addEventListener('pointercancel', finish);
    stage.addEventListener('lostpointercapture', finish);
    window.addEventListener('blur', finish);
    // Context menus fire on pointer-down on some platforms. Reserve the right
    // button within the simulation, instead of pretending we can replay a menu.
    stage.addEventListener('contextmenu', e => e.preventDefault());
    stage.addEventListener('keydown', e => {
      if (e.key === 'Escape') { finish(); report('Returning to the desktop you started on.'); }
      else if (e.key === 'Enter') report('Landing on your selected desktop.');
    }, true);
    stage.addEventListener('wheel', e => {
      if (!e.ctrlKey || !e.altKey) return;
      const now = performance.now();
      // Consume one opening burst; residual wheel events must not immediately
      // zoom back into the canvas while its entrance is still running.
      if (now < wheelOpeningUntil) {e.preventDefault();e.stopImmediatePropagation();return;}
      // Once open, use the study's existing pointer-anchored pinch/zoom path.
      if (getState().zoom >= 1.98) return;
      e.preventDefault(); e.stopImmediatePropagation();
      if (now-wheelAt > 200) wheelTotal=0;
      wheelAt=now;
      const dy=e.deltaY*(e.deltaMode===1?16:e.deltaMode===2?stage.clientHeight:1);
      wheelTotal = Math.max(0,wheelTotal+dy);
      if (wheelTotal>=18) {wheelTotal=0;wheelOpeningUntil=now+300;open();}
      else report('Ctrl + Option + scroll down to open the canvas.');
    }, {capture:true,passive:false});
  };
})();
