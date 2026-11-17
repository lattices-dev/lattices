import { useEffect, useRef, useState } from 'react'
import '../styles/hyperspace-showcase.css'

const demoPath = '/demos/hyperspace/index.html'

export function HyperspaceShowcase() {
  const [active, setActive] = useState(false)
  const previewRef = useRef<HTMLIFrameElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  useEffect(() => { if (active) previewRef.current?.focus() }, [active])
  return (
    <section className="hyperspace-showcase home-sec" id="hyperspace" aria-labelledby="hyperspace-title">
      <div className="hyperspace-showcase-heading">
        <div>
          <h2 id="hyperspace-title">Make room for what’s next.</h2>
          <p>Meet Hyperspace. Choose your windows, explore an arrangement, then put everything in place.</p>
        </div>
        <a href={demoPath} data-router="reload" target="_blank" rel="noopener noreferrer">
          Open full screen <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M4 12 12 4M4 4h8v8" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </a>
      </div>
      <div className={`hyperspace-showcase-stage${active ? ' is-active' : ''}`}>
        <img src="/demos/hyperspace/poster.webp" width="1672" height="941" loading="lazy"
          alt="Hyperspace’s luminous desktop overview: selected windows, a layout preview, and a floating glass toolbar." />
        {active ? (
          <iframe
            ref={previewRef}
            src={demoPath}
            title="Try Hyperspace with simulated windows"
            loading="eager"
            sandbox="allow-scripts"
          />
        ) : (
          <>
            <button ref={triggerRef} type="button" onClick={() => setActive(true)}>
              Try Hyperspace <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
            </button>
          </>
        )}
      </div>
      <div className="hyperspace-showcase-caption">
        <span>Interactive desktop preview · Simulated windows</span>
        {active ? <button type="button" onClick={() => { setActive(false); requestAnimationFrame(() => triggerRef.current?.focus()) }}>Close preview</button> :
          <span>Select · Preview · Apply</span>}
      </div>
    </section>
  )
}
