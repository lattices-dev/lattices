'use client'

import { useEffect, useRef, useState } from 'react'
import { DemoChromeBar, MockTitleBar, SectionHeader, Reveal } from './shared'

/** Distilled priority note placed on the desk. */
type DeskNote = {
  id: string
  stack: 'p0' | 'p1'
  file: string
  line: string
  /** percent positions inside the desktop surface */
  x: number
  y: number
  w: number
}

const NOTES: DeskNote[] = [
  {
    id: 'p0a',
    stack: 'p0',
    file: 'p0-landing.md',
    line: 'Ship cream landing — default theme + cut man-page chrome',
    x: 4,
    y: 12,
    w: 46,
  },
  {
    id: 'p0b',
    stack: 'p0',
    file: 'p0-fling.md',
    line: 'Fix fling-to-edge crash before the next release',
    x: 7,
    y: 42,
    w: 44,
  },
  {
    id: 'p0c',
    stack: 'p0',
    file: 'p0-save.md',
    line: 'Flush pending saves on panel close / quit — never trust debounce',
    x: 5,
    y: 70,
    w: 47,
  },
  {
    id: 'p1a',
    stack: 'p1',
    file: 'p1-scout.md',
    line: 'Scout broker reconnect on wake — dispatch recovery path',
    x: 54,
    y: 14,
    w: 42,
  },
  {
    id: 'p1b',
    stack: 'p1',
    file: 'p1-workspaces.md',
    line: 'Workspace brands as generic treatments, not product skins',
    x: 52,
    y: 42,
    w: 44,
  },
  {
    id: 'p1c',
    stack: 'p1',
    file: 'p1-cli.md',
    line: 'Document blink workspace + live reconcile for agents',
    x: 56,
    y: 68,
    w: 40,
  },
]

/**
 * Script beats.
 * - `tool` with `silent: true` still drives the desk, but stays out of the transcript
 *   (writes are felt on the desktop, not as a wall of log lines).
 * - Non-silent tools are a whisper under the prose.
 */
type Event =
  | { kind: 'user'; text: string }
  | { kind: 'text'; text: string }
  | {
      kind: 'tool'
      name: string
      detail: string
      silent?: boolean
      revealId?: string
    }
  | { kind: 'done'; text: string }

const SCRIPT: Event[] = [
  {
    kind: 'user',
    text: 'look at my last 24h and group my notes by top priorities — then lay them out on my desktop',
  },
  {
    kind: 'text',
    text: 'Scanning what you touched today, ranking into P0 / P1, then parking a one-liner per item on the desk.',
  },
  {
    kind: 'tool',
    name: 'bash',
    detail: 'blink ls --since 24h',
  },
  {
    kind: 'tool',
    name: 'read',
    detail: 'standup.md',
  },
  {
    kind: 'tool',
    name: 'bash',
    detail: 'blink search --since 24h',
  },
  {
    kind: 'text',
    text: 'P0 is ship-or-break. P1 is this week. Placing summaries now.',
  },
  // writes: silent — the panels are the feedback
  { kind: 'tool', name: 'write', detail: 'p0-landing.md', silent: true, revealId: 'p0a' },
  { kind: 'tool', name: 'write', detail: 'p0-fling.md', silent: true, revealId: 'p0b' },
  { kind: 'tool', name: 'write', detail: 'p0-save.md', silent: true, revealId: 'p0c' },
  { kind: 'tool', name: 'write', detail: 'p1-scout.md', silent: true, revealId: 'p1a' },
  { kind: 'tool', name: 'write', detail: 'p1-workspaces.md', silent: true, revealId: 'p1b' },
  { kind: 'tool', name: 'write', detail: 'p1-cli.md', silent: true, revealId: 'p1c' },
  {
    kind: 'done',
    text: 'Laid out 6 panels from the last 24h — P0 left, P1 right. Everything else stays in the folder.',
  },
]

type LogItem =
  | { kind: 'user'; text: string }
  | { kind: 'text'; text: string }
  | { kind: 'tool'; name: string; detail: string }
  | { kind: 'done'; text: string }

function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex gap-2.5">
      <span className="mt-[2px] shrink-0 text-[11px] text-acc" aria-hidden>
        ❯
      </span>
      <p className="text-[12.5px] leading-[1.55] text-[var(--text)]">{text}</p>
    </div>
  )
}

function AssistantText({ text }: { text: string }) {
  return <p className="text-[12.5px] leading-[1.65] text-dimx pl-[1.15rem]">{text}</p>
}

/** Secondary to prose — quieter, but still legible on cream. */
function ToolWhisper({ name, detail }: { name: string; detail: string }) {
  return (
    <div className="pl-[1.15rem] text-[10.5px] leading-[1.5] text-dimx/80 truncate font-mono">
      <span className="text-faintx">{name}</span>
      <span className="mx-1.5 text-faintx">·</span>
      <span>{detail}</span>
    </div>
  )
}

function DoneLine({ text }: { text: string }) {
  return <p className="pl-[1.15rem] text-[12.5px] leading-[1.55] text-[var(--text)]">{text}</p>
}

export function AgentFilm() {
  return (
    <section id="film" className="scroll-mt-16 border-t border-linex py-20 md:py-28">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <SectionHeader
          tag="DEMO"
          title={
            <>
              Pi types the commands. <span className="text-acc">Canvas arranges the desk.</span>
            </>
          }
          sub="Recorded before the rename to Canvas, this iTerm2 session uses the compatible blink CLI to create, move, hide, and restore spatial notes — with the desktop itself as the workspace."
        />

        <Reveal>
          <div className="corner-frame">
            <div className="overflow-hidden rounded-[8px] border border-linex bg-panelx">
              <MockTitleBar
                title={
                  <span className="inline-flex items-center gap-2">
                    <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-[var(--acc)]" aria-hidden />
                    Pi → CLI → spatial desk
                  </span>
                }
                trailing={<span className="text-faintx">00:47 · sound on</span>}
              />

              <div className="aspect-video bg-[#050708]">
                <video
                  className="block h-full w-full object-contain"
                  controls
                  playsInline
                  preload="metadata"
                  poster="/demos/blink-spatial-demo-poster.jpg"
                  aria-label="Pi drives Canvas (then Blink) through the command line to create and arrange spatial notes"
                >
                  <source src="/demos/blink-spatial-demo.mp4" type="video/mp4" />
                </video>
              </div>

              <div className="flex flex-col gap-2 border-t border-linex px-3 py-2.5 text-[10px] text-dimx sm:flex-row sm:items-center sm:justify-between">
                <span>native panels · plain markdown · positions persist</span>
                <a
                  href="/demos/blink-spatial-demo.mp4"
                  className="shrink-0 text-acc underline-offset-4 hover:underline"
                >
                  open video ↗
                </a>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

function TicketPanel({ note, active }: { note: DeskNote; active: boolean }) {
  return (
    <div
      className={[
        'absolute rounded-[7px] glass-note overflow-hidden',
        active ? 'desk-note-in' : 'opacity-0 pointer-events-none',
      ].join(' ')}
      style={{
        left: `${note.x}%`,
        top: `${note.y}%`,
        width: `${note.w}%`,
        maxWidth: 220,
        zIndex: active ? 10 : 1,
        transition: 'opacity 0.85s ease',
      }}
    >
      <div className="flex items-center justify-between gap-2 border-b border-[rgba(255,255,255,0.12)] px-2.5 py-1.5">
        <span className="truncate text-[9px] font-medium leading-none text-[rgba(250,250,250,0.92)]">{note.file}</span>
        <span className="shrink-0 text-[8px] uppercase tracking-[0.12em] text-[rgba(220,220,220,0.65)]">
          {note.stack}
        </span>
      </div>
      <div className="px-2.5 py-2">
        <p className="line-clamp-2 text-[10px] leading-[1.45] text-[rgba(240,240,240,0.92)]">{note.line}</p>
      </div>
    </div>
  )
}

export default function AgentCaseStudy() {
  const [log, setLog] = useState<LogItem[]>([])
  const [visible, setVisible] = useState<Set<string>>(() => new Set())
  const [status, setStatus] = useState<'idle' | 'working' | 'done'>('idle')
  /** One rolling whisper while silent writes land panels. */
  const [placing, setPlacing] = useState<string | null>(null)
  const logBoxRef = useRef<HTMLDivElement>(null)
  const cancelledRef = useRef(false)

  useEffect(() => {
    cancelledRef.current = false
    const timeouts: number[] = []
    const reduced =
      typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const wait = (ms: number) =>
      new Promise<void>((res) => {
        // Keep reduced-motion short, but never frantic in the normal path
        const id = window.setTimeout(res, reduced ? Math.min(ms, 40) : ms)
        timeouts.push(id)
      })

    const run = async () => {
      while (!cancelledRef.current) {
        setLog([])
        setVisible(new Set())
        setStatus('idle')
        setPlacing(null)
        await wait(1200)

        for (const step of SCRIPT) {
          if (cancelledRef.current) return

          if (step.kind === 'user') {
            setLog((prev) => [...prev, step])
            setStatus('working')
            await wait(1400)
            continue
          }

          if (step.kind === 'text') {
            setLog((prev) => [...prev, step])
            await wait(1600)
            continue
          }

          if (step.kind === 'tool') {
            if (!step.silent) {
              setLog((prev) => [...prev, { kind: 'tool', name: step.name, detail: step.detail }])
              await wait(reduced ? 50 : 700)
            } else {
              // silent write: one rolling line, desk gets the panel — unhurried
              setPlacing(step.detail)
              await wait(reduced ? 40 : 720)
            }

            if (cancelledRef.current) return

            if (step.revealId) {
              setVisible((prev) => {
                const next = new Set(prev)
                next.add(step.revealId!)
                return next
              })
              await wait(reduced ? 30 : 480)
            }
            continue
          }

          if (step.kind === 'done') {
            setPlacing(null)
            setLog((prev) => [...prev, step])
            setStatus('done')
            // Rest on the finished board — no rush to loop
            await wait(reduced ? 2400 : 11000)
            // Soft clear: fade panels first, then restart
            setVisible(new Set())
            await wait(reduced ? 200 : 900)
          }
        }
      }
    }

    run()
    return () => {
      cancelledRef.current = true
      timeouts.forEach((t) => clearTimeout(t))
    }
  }, [])

  // Gentle stick-to-bottom — no smooth-scroll chase
  useEffect(() => {
    const box = logBoxRef.current
    if (!box) return
    box.scrollTop = box.scrollHeight
  }, [log, placing])

  const p0Count = NOTES.filter((n) => n.stack === 'p0' && visible.has(n.id)).length
  const p1Count = NOTES.filter((n) => n.stack === 'p1' && visible.has(n.id)).length

  return (
    <section id="desk" className="scroll-mt-16 py-20 md:py-28 border-t border-linex">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <SectionHeader
          tag="CASE STUDY"
          title={
            <>
              Last 24 hours, <span className="text-acc">laid out by priority.</span>
            </>
          }
          sub={
            <>
              Ask your coding agent to read what you touched, group it into top priorities, and
              park a one-liner per item on the desktop. The rest stays in the folder — only what
              matters is in view.
            </>
          }
        />

        <Reveal className="grid items-start gap-5 lg:grid-cols-[0.95fr_1.15fr]">
          {/* coding-agent transcript — conversation leads; tools whisper */}
          <div className="flex h-[380px] flex-col overflow-hidden rounded-[8px] border border-linex bg-panelx sm:h-[420px]">
            <MockTitleBar
              title="claude"
              detail="~/Notes · last 24h"
              trailing={
                <>
                  {status === 'working' && <span className="text-dimx">working</span>}
                  {status === 'done' && <span className="font-medium text-acc">done</span>}
                  {status === 'idle' && <span className="text-dimx">ready</span>}
                </>
              }
            />

            <div
              ref={logBoxRef}
              className="flex-1 min-h-0 px-3.5 py-3.5 space-y-3.5 overflow-y-auto"
              aria-live="polite"
              aria-atomic="false"
            >
              {log.map((item, i) => {
                if (item.kind === 'user') return <UserBubble key={i} text={item.text} />
                if (item.kind === 'text') return <AssistantText key={i} text={item.text} />
                if (item.kind === 'tool')
                  return <ToolWhisper key={i} name={item.name} detail={item.detail} />
                return <DoneLine key={i} text={item.text} />
              })}

              {/* rolling whisper while silent writes land — never a list of six writes */}
              {placing && (
                <div className="pl-[1.15rem] text-[10.5px] leading-[1.5] text-dimx/80 truncate font-mono">
                  <span className="text-faintx">write</span>
                  <span className="mx-1.5 text-faintx">·</span>
                  <span>{placing}</span>
                </div>
              )}
            </div>

            <div className="shrink-0 flex items-center justify-between border-t border-linex px-3.5 py-2 text-[10px] text-dimx">
              <span>{status === 'done' ? 'desk ready' : status === 'working' ? 'ranking…' : 'ready'}</span>
              <span className="hidden sm:inline text-faintx">panels update live</span>
            </div>
          </div>

          {/* desktop with priority stacks */}
          <div className="corner-frame flex h-[380px] flex-col sm:h-[420px]">
            <DemoChromeBar
              title="~/Desktop"
              detail="— prioritized board"
              trailing={
                <>
                  <span>
                    p0 <span className="font-semibold tabular-nums text-acc">{p0Count}</span>
                  </span>
                  <span className="text-faintx">·</span>
                  <span>
                    p1 <span className="font-semibold tabular-nums text-acc">{p1Count}</span>
                  </span>
                </>
              }
            />

            <div
              className="demo-desktop relative flex-1 min-h-0 overflow-hidden rounded-b-[8px] border border-linex"
              role="img"
              aria-label="Desktop with priority notes laid out by the agent"
            >
              <div
                className="pointer-events-none absolute inset-y-4 left-3 w-[48%] rounded-[10px] border border-dashed border-[rgba(var(--line-rgb),0.75)] bg-[rgba(var(--bg-rgb),0.18)]"
                aria-hidden
              />
              <div
                className="pointer-events-none absolute inset-y-4 right-3 w-[44%] rounded-[10px] border border-dashed border-[rgba(var(--line-rgb),0.75)] bg-[rgba(var(--bg-rgb),0.14)]"
                aria-hidden
              />
              <div className="pointer-events-none absolute top-3 left-5 text-[9px] tracking-[0.14em] uppercase font-semibold text-dimx">
                p0 · today
              </div>
              <div className="pointer-events-none absolute top-3 right-[calc(3%+0.5rem)] text-[9px] tracking-[0.14em] uppercase font-semibold text-dimx">
                p1 · this week
              </div>

              {NOTES.map((note) => (
                <TicketPanel key={note.id} note={note} active={visible.has(note.id)} />
              ))}

              {visible.size === 0 && (
                <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
                  <p className="text-[12px] text-dimx text-center max-w-[15rem] leading-relaxed">
                    agent is ranking the last 24h…
                  </p>
                </div>
              )}

              <div className="absolute bottom-2 left-3 right-3 flex justify-between text-[10px] text-dimx pointer-events-none">
                <span>
                  panels: {visible.size}/{NOTES.length}
                </span>
                <span className="hidden sm:inline">summaries only · rest stays filed</span>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
