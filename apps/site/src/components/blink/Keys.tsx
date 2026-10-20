import {
  SectionHeader,
  Chord,
  HyperChord,
  HYPER_EXPAND,
  HYPER_GLYPH,
  Reveal,
} from './shared'

const KEYS: {
  action: string
  scope: 'global' | 'panel'
  /** Accessible full shortcut name */
  spoken: string
  /** Visual chord */
  visual: 'hyper' | 'chord'
  letter?: string
  keys?: string[]
}[] = [
  {
    action: 'new note, anywhere',
    scope: 'global',
    spoken: 'Control Option Shift Command N',
    visual: 'hyper',
    letter: 'N',
  },
  {
    action: 'show or hide all notes',
    scope: 'global',
    spoken: 'Control Option Shift Command B',
    visual: 'hyper',
    letter: 'B',
  },
  {
    action: 'grid overlay',
    scope: 'global',
    spoken: 'Control Option Shift Command C',
    visual: 'hyper',
    letter: 'C',
  },
  {
    action: 'flip read / edit',
    scope: 'panel',
    spoken: 'Command Shift P',
    visual: 'chord',
    keys: ['⌘', '⇧', 'P'],
  },
  {
    action: 'close panel',
    scope: 'panel',
    spoken: 'Command W',
    visual: 'chord',
    keys: ['⌘', 'W'],
  },
]

export default function Keys() {
  return (
    <section id="keys" className="scroll-mt-16 py-20 md:py-28 border-t border-linex">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <SectionHeader
          tag="KEYS"
          title={
            <>
              Everything is <span className="text-acc">a keystroke away</span>.
            </>
          }
          sub="A modifier no app already owns. Every binding is rewritable in config.json."
        />

        <Reveal>
          <p className="mb-4">
            <span
              className="inline-flex flex-wrap items-center gap-x-1.5 gap-y-1 rounded-[6px] border border-linex bg-panelx px-2.5 py-1.5 text-[12px]"
              role="note"
              aria-label={`${HYPER_GLYPH} Hyper equals Control Option Shift Command`}
            >
              <span className="font-semibold text-[var(--text)]" aria-hidden>
                {HYPER_GLYPH}
              </span>
              <span className="text-dimx" aria-hidden>
                Hyper
              </span>
              <span className="text-faintx" aria-hidden>
                =
              </span>
              <Chord keys={[...HYPER_EXPAND]} />
            </span>
          </p>

          <div className="overflow-hidden rounded-[8px] border border-linex bg-panelx">
            <div
              className="hidden grid-cols-[minmax(0,1fr)_4.75rem_auto] gap-x-6 border-b border-linex bg-panel2x px-4 py-2.5 text-[10px] uppercase tracking-[0.14em] text-faintx sm:grid"
              role="row"
            >
              <span>action</span>
              <span className="text-left">scope</span>
              <span className="text-right">chord</span>
            </div>
            {KEYS.map((r) => (
              <div
                key={r.action}
                className="grid grid-cols-1 items-center gap-2 border-b border-[rgba(var(--line-rgb),0.55)] px-4 py-3.5 transition-colors last:border-b-0 hover:bg-[rgba(var(--acc-rgb),0.03)] sm:grid-cols-[minmax(0,1fr)_4.75rem_auto] sm:gap-x-6"
              >
                <div className="text-[13px] text-[var(--text)]">{r.action}</div>
                <div className="sm:justify-self-start">
                  <span className="inline-flex min-w-[3.25rem] items-center justify-center rounded-[3px] border border-linex px-1.5 py-[2px] text-[9px] uppercase tracking-[0.12em] text-faintx">
                    {r.scope}
                  </span>
                </div>
                <div className="sm:justify-self-end">
                  {r.visual === 'hyper' && r.letter ? (
                    <HyperChord letter={r.letter} action={r.action} />
                  ) : (
                    <Chord keys={r.keys!} label={`${r.action}: ${r.spoken}`} />
                  )}
                </div>
              </div>
            ))}
          </div>
        </Reveal>
      </div>
    </section>
  )
}
