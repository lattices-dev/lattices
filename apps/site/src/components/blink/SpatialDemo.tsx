import { useCallback, useEffect, useRef, useState } from 'react'
import { DemoChromeBar, HyperChord, HYPER_GLYPH } from './shared'

interface DemoNote {
  id: number
  x: number
  y: number
  w: number
  title: string
  lines: string[]
  hidden: boolean
  vanishing: boolean
  z: number
}

const SAMPLES: { title: string; lines: string[] }[] = [
  { title: 'standup.md', lines: ['## Fri', '- ship the landing', '- port the palette'] },
  { title: 'roadmap.md', lines: ['## v2.1', '- [[sheets]] per note', '- cli: blink watch'] },
  { title: 'inbox.md', lines: ['- read: NSPanel docs', '- atomic writes, again'] },
  { title: 'scratch.md', lines: ['π ≈ 3.14159', 'plain markdown, always'] },
  { title: 'reading.md', lines: ['- the unix philosophy', '- codemirror 6 guide'] },
  { title: 'ideas.md', lines: ['- grid snap ±8px', '- sheet: marginalia'] },
]

const NOTE_W = 216
const MAX_NOTES = 6

const DEFAULT_LAYOUT = [
  { sample: 0, x: 49, y: 34, w: 216, z: 11 },
  { sample: 1, x: 203, y: 115, w: 216, z: 12 },
  { sample: 2, x: 50, y: 208, w: 216, z: 13 },
] as const

let uid = 0

export default function SpatialDemo() {
  const ref = useRef<HTMLDivElement>(null)
  const hoverRef = useRef(false)
  const mouseRef = useRef({ x: 120, y: 120 })
  const zRef = useRef(10)
  const [notes, setNotes] = useState<DemoNote[]>([])
  const [grid, setGrid] = useState(false)
  const [allHidden, setAllHidden] = useState(false)
  const [dragInfo, setDragInfo] = useState<{ id: number; x: number; y: number } | null>(null)
  const dragRef = useRef<{ id: number; dx: number; dy: number } | null>(null)

  const clamp = useCallback((x: number, y: number) => {
    const el = ref.current
    if (!el) return { x, y }
    const r = el.getBoundingClientRect()
    return {
      x: Math.max(4, Math.min(x, r.width - NOTE_W - 4)),
      y: Math.max(4, Math.min(y, r.height - 150)),
    }
  }, [])

  const spawn = useCallback(
    (x?: number, y?: number) => {
      const el = ref.current
      if (!el) return
      const r = el.getBoundingClientRect()
      const px = x ?? mouseRef.current.x
      const py = y ?? mouseRef.current.y
      const pos = clamp(px - NOTE_W / 2, py - 20)
      setNotes((prev) => {
        const sample = SAMPLES[prev.length % SAMPLES.length]
        const next: DemoNote = {
          id: ++uid,
          x: pos.x,
          y: pos.y,
          w: NOTE_W,
          title: sample.title,
          lines: sample.lines,
          hidden: false,
          vanishing: false,
          z: ++zRef.current,
        }
        const list = [...prev, next]
        return list.length > MAX_NOTES ? list.slice(list.length - MAX_NOTES) : list
      })
      void r
    },
    [clamp],
  )

  const resetScene = useCallback(() => {
    const next = DEFAULT_LAYOUT.map((item) => {
      const pos = clamp(item.x, item.y)
      return {
        id: ++uid,
        x: pos.x,
        y: pos.y,
        w: item.w,
        title: SAMPLES[item.sample].title,
        lines: SAMPLES[item.sample].lines,
        hidden: false,
        vanishing: false,
        z: item.z,
      }
    })
    zRef.current = DEFAULT_LAYOUT[DEFAULT_LAYOUT.length - 1].z
    setAllHidden(false)
    setNotes(next)
  }, [clamp])

  const toggleBlink = useCallback(() => {
    setAllHidden((h) => {
      const target = !h
      setNotes((prev) => prev.map((n) => ({ ...n, hidden: target })))
      return target
    })
  }, [])

  /* keyboard: press N while hovering the surface */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!hoverRef.current) return
      if (e.key.toLowerCase() === 'n' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        spawn()
      }
      if (e.key.toLowerCase() === 'b' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        toggleBlink()
      }
      if (e.key.toLowerCase() === 'c' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        setGrid((g) => !g)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [spawn, toggleBlink])

  /* Canonical first-load/reset composition. These are the exact demo-window
     coordinates and sizes shown in the product mock; dragging remains live. */
  const seededRef = useRef(false)
  useEffect(() => {
    if (seededRef.current) return
    seededRef.current = true
    resetScene()
  }, [resetScene])

  /* drag */
  const onPanelPointerDown = (e: React.PointerEvent, note: DemoNote) => {
    e.stopPropagation()
    ;(e.target as HTMLElement).setPointerCapture?.(e.pointerId)
    dragRef.current = { id: note.id, dx: e.clientX - note.x, dy: e.clientY - note.y }
    setNotes((prev) => prev.map((n) => (n.id === note.id ? { ...n, z: ++zRef.current } : n)))
  }

  useEffect(() => {
    const move = (e: PointerEvent) => {
      const d = dragRef.current
      if (!d) return
      const el = ref.current
      if (!el) return
      const r = el.getBoundingClientRect()
      const pos = clamp(e.clientX - d.dx, e.clientY - d.dy)
      setDragInfo({ id: d.id, x: Math.round(pos.x), y: Math.round(pos.y) })
      setNotes((prev) => prev.map((n) => (n.id === d.id ? { ...n, x: pos.x, y: pos.y } : n)))
      void r
    }
    const up = () => {
      dragRef.current = null
      setDragInfo(null)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    return () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
  }, [clamp])

  const onSurfaceMove = (e: React.PointerEvent) => {
    const r = ref.current!.getBoundingClientRect()
    mouseRef.current = { x: e.clientX - r.left, y: e.clientY - r.top }
  }

  const demoBtn =
    'inline-flex h-7 items-center rounded-[4px] border border-line2x bg-[var(--panel)] px-2 text-[10px] leading-none text-dimx transition-colors hover:border-[rgba(var(--acc-rgb),0.4)] hover:text-acc'
  const demoBtnOn =
    'inline-flex h-7 items-center rounded-[4px] border border-[rgba(var(--acc-rgb),0.45)] bg-[var(--acc-soft)] px-2 text-[10px] leading-none text-acc transition-colors'

  return (
    <div className="corner-frame select-none" role="region" aria-label="Spatial notes demo">
      <DemoChromeBar
        statusDot
        title="~/Desktop"
        detail="— live demo"
        trailing={
          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={() => spawn()}
              title="New note — Control Option Shift Command N"
              aria-label="New note, Control Option Shift Command N"
              className={demoBtn}
            >
              {HYPER_GLYPH}N
            </button>
            <button
              type="button"
              onClick={toggleBlink}
              title="Blink all / none — Control Option Shift Command B"
              aria-label="Blink all panels, Control Option Shift Command B"
              aria-pressed={allHidden}
              className={allHidden ? demoBtnOn : demoBtn}
            >
              {HYPER_GLYPH}B
            </button>
            <button
              type="button"
              onClick={() => setGrid((g) => !g)}
              title="Grid overlay — Control Option Shift Command C"
              aria-label="Toggle grid overlay, Control Option Shift Command C"
              aria-pressed={grid}
              className={grid ? demoBtnOn : demoBtn}
            >
              {HYPER_GLYPH}C
            </button>
            <button
              type="button"
              onClick={resetScene}
              title="Reset surface"
              aria-label="Reset demo"
              className="inline-flex h-7 items-center rounded-[4px] border border-line2x bg-[var(--panel)] px-2 text-[10px] leading-none text-faintx transition-colors hover:border-[rgba(var(--acc-rgb),0.35)] hover:text-[var(--text)]"
            >
              reset
            </button>
          </div>
        }
      />

      {/* surface — premium layered desktop */}
      <div
        ref={ref}
        data-grid={grid ? 'true' : undefined}
        onPointerEnter={() => (hoverRef.current = true)}
        onPointerLeave={() => (hoverRef.current = false)}
        onPointerMove={onSurfaceMove}
        onPointerDown={(e) => {
          if (e.target === e.currentTarget || (e.target as HTMLElement).dataset.surface === 'grid') {
            spawn(e.clientX - ref.current!.getBoundingClientRect().left, e.clientY - ref.current!.getBoundingClientRect().top)
          }
        }}
        className="demo-desktop relative h-[340px] sm:h-[380px] md:h-[420px] overflow-hidden rounded-b-[8px] border border-linex cursor-crosshair"
      >
        {/* soft ambient wash — extra depth without color noise */}
        <div
          className="pointer-events-none absolute inset-0"
          aria-hidden
          style={{
            background:
              'radial-gradient(ellipse 55% 40% at 72% 28%, rgba(255,255,255,0.12), transparent 70%), radial-gradient(ellipse 40% 50% at 18% 70%, rgba(0,0,0,0.06), transparent 65%)',
          }}
        />
        {/* grid rulers */}
        {grid && (
          <div data-surface="grid" className="absolute inset-0 pointer-events-none">
            {[80, 160, 240, 320, 400].map((x) => (
              <span key={x} className="absolute top-1 text-[9px] text-faintx/80" style={{ left: x + 3 }}>
                {x}
              </span>
            ))}
            {[80, 160, 240, 320].map((y) => (
              <span key={y} className="absolute left-1.5 text-[9px] text-faintx/80" style={{ top: y + 3 }}>
                {y}
              </span>
            ))}
          </div>
        )}

        {/* empty state hint — fades away once the scene has notes */}
        <div
          className={`absolute inset-0 flex flex-col items-center justify-center gap-2.5 px-4 pointer-events-none pb-8 transition-opacity duration-500 ${
            notes.length === 0 ? 'opacity-100' : 'opacity-0'
          }`}
        >
          <div className="flex items-center gap-2 text-[12px] text-faintx">
            <HyperChord letter="N" action="New note" />
          </div>
          <p className="text-[11px] text-faintx text-center max-w-[18rem] leading-relaxed">
            click anywhere — or press <span className="text-acc">N</span> — to drop a note
          </p>
        </div>

        {/* notes */}
        {notes.map((n) => (
          <div
            key={n.id}
            onPointerDown={(e) => onPanelPointerDown(e, n)}
            className={[
              'absolute rounded-[8px] glass-note note-spawn cursor-grab active:cursor-grabbing',
              n.hidden ? 'opacity-0 scale-95 pointer-events-none' : '',
            ].join(' ')}
            style={{
              left: n.x,
              top: n.y,
              width: n.w,
              zIndex: n.z,
              transition: 'opacity 0.22s ease, transform 0.22s ease',
            }}
          >
            <div className="flex min-h-7 items-center justify-between gap-2 border-b border-[rgba(255,248,236,0.12)] px-2.5 py-1.5">
              <span className="truncate text-[10px] font-medium leading-none text-[rgba(245,242,236,0.88)]">{n.title}</span>
              <span className="shrink-0 text-[9px] tabular-nums leading-none text-[rgba(200,196,188,0.55)]">
                {dragInfo?.id === n.id ? (
                  <span className="text-[rgba(245,242,236,0.9)]">
                    x:{String(dragInfo.x).padStart(3, '0')} y:{String(dragInfo.y).padStart(3, '0')}
                  </span>
                ) : (
                  `x:${String(Math.round(n.x)).padStart(3, '0')} y:${String(Math.round(n.y)).padStart(3, '0')}`
                )}
              </span>
            </div>
            <div className="space-y-[3px] px-2.5 py-2">
              {n.lines.map((l, i) => (
                <div
                  key={i}
                  className={`text-[10px] leading-[1.5] whitespace-nowrap overflow-hidden ${
                    l.startsWith('##')
                      ? 'font-semibold text-[rgba(245,242,236,0.92)]'
                      : 'text-[rgba(200,196,188,0.78)]'
                  }`}
                >
                  {l}
                </div>
              ))}
            </div>
          </div>
        ))}

        {/* bottom-left readout */}
        <div className="absolute bottom-2 left-3 text-[9px] text-faintx pointer-events-none">
          panels: {notes.filter((n) => !n.hidden).length}/{notes.length}
          {allHidden && <span className="text-acc"> · blinked out — {HYPER_GLYPH}B to recall</span>}
        </div>
        <div className="absolute bottom-2 right-3 text-[9px] text-faintx pointer-events-none hidden sm:block">
          drag panels · state persists (x, y, w, h)
        </div>
      </div>
    </div>
  )
}
