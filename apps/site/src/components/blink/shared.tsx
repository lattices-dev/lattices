import { useEffect, useRef, useState, type ReactNode } from 'react'

/* ------------------------------ scroll reveal ----------------------------- */

/** Fades/rises content in when it enters the viewport (once). SSR renders it
 *  fully visible — the hidden state is only armed on the client, so no-JS and
 *  first paint are never blank. Reduced motion is handled by the global CSS. */
export function Reveal({
  children,
  className = '',
  delay = 0,
}: {
  children: ReactNode
  className?: string
  delay?: number
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [armed, setArmed] = useState(false)
  const [inView, setInView] = useState(false)

  useEffect(() => {
    queueMicrotask(() => setArmed(true))
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true)
          io.disconnect()
        }
      },
      { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <div
      ref={ref}
      className={`${armed ? 'reveal' : ''} ${inView ? 'reveal-in' : ''} ${className}`}
      style={delay ? { transitionDelay: `${delay}ms` } : undefined}
    >
      {children}
    </div>
  )
}

/* ---------------------------------- kbd ---------------------------------- */

/** Visual stand-in for the Hyper modifier cluster (⌃⌥⇧⌘). */
export const HYPER_GLYPH = '◆'
export const HYPER_EXPAND = '⌃⌥⇧⌘'
export const HYPER_SPOKEN = 'Control Option Shift Command'

export function Kbd({ children, wide }: { children: ReactNode; wide?: boolean }) {
  return (
    <span
      className={[
        'kbd inline-flex items-center justify-center h-[22px] rounded-[5px] px-[7px] text-[11px] leading-none',
        wide ? 'min-w-[34px]' : 'min-w-[22px]',
      ].join(' ')}
    >
      {children}
    </span>
  )
}

export function Chord({ keys, label }: { keys: string[]; label?: string }) {
  return (
    <span
      className="inline-flex items-center gap-[4px]"
      role={label ? 'img' : undefined}
      aria-label={label}
    >
      {keys.map((k, i) => (
        <Kbd key={i} wide={k.length > 1 && k !== HYPER_GLYPH}>
          {k}
        </Kbd>
      ))}
    </span>
  )
}

/** Global Hyper chord: diamond glyph + final letter; full shortcut in accessible label. */
export function HyperChord({ letter, action }: { letter: string; action?: string }) {
  const full = `${HYPER_SPOKEN} ${letter}`
  return (
    <Chord
      keys={[HYPER_GLYPH, letter]}
      label={action ? `${action}: ${full}` : full}
    />
  )
}

/* --------------------------- mock window chrome --------------------------- */

/** Shared title bar for in-page terminal / file / preview mocks. */
export function MockTitleBar({
  title,
  detail,
  trailing,
  dots = false,
  className = '',
}: {
  title: ReactNode
  detail?: ReactNode
  trailing?: ReactNode
  dots?: boolean
  className?: string
}) {
  return (
    <div
      className={[
        'flex min-h-9 shrink-0 items-center justify-between gap-3 border-b border-linex bg-panel2x px-3 py-1.5',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <div className="flex min-w-0 items-center gap-2">
        {dots && (
          <span className="flex items-center gap-1" aria-hidden>
            <span className="h-[7px] w-[7px] rounded-full bg-[var(--ghost)]" />
            <span className="h-[7px] w-[7px] rounded-full bg-[var(--faint)]" />
            <span className="h-[7px] w-[7px] rounded-full bg-[var(--dim)]" />
          </span>
        )}
        <span className="truncate text-[11px] font-medium text-[var(--text)]">{title}</span>
        {detail != null && detail !== '' && (
          <span className="hidden min-w-0 truncate text-[10px] text-faintx sm:inline">{detail}</span>
        )}
      </div>
      {trailing != null && (
        <div className="flex shrink-0 items-center gap-2 text-[10px] text-dimx">{trailing}</div>
      )}
    </div>
  )
}

/** Shared desk / live-demo chrome strip (uses --demo-chrome tokens). */
export function DemoChromeBar({
  title,
  detail,
  trailing,
  statusDot = false,
  className = '',
}: {
  title: ReactNode
  detail?: ReactNode
  trailing?: ReactNode
  statusDot?: boolean
  className?: string
}) {
  return (
    <div
      className={[
        'demo-chrome flex min-h-9 shrink-0 items-center justify-between gap-2 border border-b-0 rounded-t-[8px] px-3 py-1.5',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <div className="flex min-w-0 items-center gap-2 text-[11px]">
        {statusDot && (
          <span className="inline-block h-[7px] w-[7px] shrink-0 rounded-full bg-[var(--acc)] pulse-dot" aria-hidden />
        )}
        <span className="truncate font-semibold text-[var(--text)]">{title}</span>
        {detail != null && (
          <span className="hidden shrink-0 text-faintx md:inline">{detail}</span>
        )}
      </div>
      {trailing != null && (
        <div className="flex shrink-0 items-center gap-1.5 text-[10px] text-dimx">{trailing}</div>
      )}
    </div>
  )
}

/* ------------------------------ section header ---------------------------- */

export function SectionHeader({
  tag,
  title,
  sub,
}: {
  tag?: string
  title: ReactNode
  sub?: ReactNode
}) {
  return (
    <div className="mb-10 md:mb-12">
      {tag && (
        <div className="label-x mb-4 flex items-center gap-3">
          <span className="text-acc" aria-hidden>
            {'//'}
          </span>
          <span>{tag}</span>
          <span className="h-px flex-1 bg-[var(--line)]" aria-hidden />
        </div>
      )}
      <h2 className="text-[24px] md:text-[32px] font-bold leading-[1.15] tracking-[-0.02em] text-[var(--text)] max-w-2xl text-balance">
        {title}
      </h2>
      {sub && (
        <div className="mt-3 max-w-xl text-[13px] md:text-[14px] leading-[1.7] text-dimx">{sub}</div>
      )}
    </div>
  )
}

/* --------------------------------- buttons -------------------------------- */

export function PrimaryButton({
  href,
  children,
}: {
  href: string
  children: ReactNode
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="group inline-flex h-11 items-center gap-2.5 rounded-[6px] bg-[var(--acc)] px-5 text-[13px] font-bold text-[var(--on-acc)] transition-[filter,box-shadow,transform] duration-150 hover:brightness-110 hover:shadow-[0_10px_28px_-8px_rgba(var(--acc-rgb),0.55)] active:translate-y-px"
    >
      {children}
    </a>
  )
}

export function GhostButton({
  href,
  children,
}: {
  href: string
  children: ReactNode
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="inline-flex h-11 items-center gap-2.5 rounded-[6px] border border-line2x bg-[var(--panel)] px-5 text-[13px] font-medium text-dimx transition-colors duration-150 hover:border-[var(--line-2)] hover:bg-panel2x hover:text-[var(--text)] active:translate-y-px"
    >
      {children}
    </a>
  )
}

/* ------------------------------- misc chips ------------------------------- */

export function Chip({ children, tone = 'default' }: { children: ReactNode; tone?: 'default' | 'acc' | 'amber' }) {
  const tones = {
    default: 'border-line2x text-dimx',
    acc: 'border-[rgba(var(--acc-rgb),0.35)] text-acc bg-[var(--acc-soft)]',
    amber: 'border-[rgba(var(--acc-rgb),0.35)] text-acc bg-[var(--acc-soft)]',
  }
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-[4px] border px-2 py-[3px] text-[11px] ${tones[tone]}`}>
      {children}
    </span>
  )
}
