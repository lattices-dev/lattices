import { SectionHeader } from './shared'

type Token = [text: string, color: 'key' | 'str' | 'num' | 'bool' | 'punct' | 'comment']

const LINES: Token[][] = [
  [['{', 'punct']],
  [['  ', 'punct'], ['"hotkeys"', 'key'], [': {', 'punct'], ['          // global chords, any app', 'comment']],
  [['    ', 'punct'], ['"newNote"', 'key'], [': ', 'punct'], ['"hyper+n"', 'str'], [',', 'punct'], ['  // summon a panel anywhere', 'comment']],
  [['    ', 'punct'], ['"blink"', 'key'], [': ', 'punct'], ['"hyper+b"', 'str'], [',', 'punct'], ['     // every panel in / out', 'comment']],
  [['    ', 'punct'], ['"grid"', 'key'], [': ', 'punct'], ['"hyper+c"', 'str'], ['     // survey the board', 'comment']],
  [['  },', 'punct']],
  [['  ', 'punct'], ['"panel"', 'key'], [': {', 'punct']],
  [['    ', 'punct'], ['"sheet"', 'key'], [': ', 'punct'], ['"dotted"', 'str'], [',', 'punct'], ['   // glass·card·dotted·bracket·marginalia', 'comment']],
  [['    ', 'punct'], ['"defaultWidth"', 'key'], [': ', 'punct'], ['420', 'num'], [',', 'punct']],
  [['    ', 'punct'], ['"defaultHeight"', 'key'], [': ', 'punct'], ['340', 'num']],
  [['  },', 'punct']],
  [['  ', 'punct'], ['"motion"', 'key'], [': {', 'punct']],
  [['    ', 'punct'], ['"entrance"', 'key'], [': ', 'punct'], ['"shimmer"', 'str'], [',', 'punct'], [' // panel spawn animation', 'comment']],
  [['    ', 'punct'], ['"durationMs"', 'key'], [': ', 'punct'], ['260', 'num'], [',', 'punct']],
  [['    ', 'punct'], ['"enabled"', 'key'], [': ', 'punct'], ['true', 'bool'], ['           // Reduce Motion is always honored', 'comment']],
  [['  },', 'punct']],
  [['  ', 'punct'], ['"editor"', 'key'], [': {', 'punct']],
  [['    ', 'punct'], ['"fontSize"', 'key'], [': ', 'punct'], ['13', 'num'], [',', 'punct']],
  [['    ', 'punct'], ['"lineHeight"', 'key'], [': ', 'punct'], ['1.75', 'num']],
  [['  }', 'punct']],
  [['}', 'punct']],
]

const COLORS: Record<Token[1], string> = {
  key: 'var(--syn-key)',
  str: 'var(--syn-str)',
  num: 'var(--syn-num)',
  bool: 'var(--syn-bool)',
  punct: 'var(--syn-punct)',
  comment: 'var(--syn-comment)',
}

export function ConfigSection() {
  return (
    <section id="config" className="py-20 md:py-28 border-t border-linex">
      <div className="mx-auto max-w-6xl px-4 md:px-6">
        <SectionHeader
          tag="CONFIGURATION"
          title={
            <>
              Configured by a file, <span className="text-acc">not a settings pane</span>.
            </>
          }
          sub="Theme, hotkeys, motion, sheets — one JSON file. Any process can edit it; Canvas watches the directory and hot-applies changes to every panel. The settings window is just a view over it."
        />

        <div className="grid gap-8 lg:grid-cols-[1.35fr_1fr] lg:gap-12 items-start">
          {/* file */}
          <div className="border border-linex rounded-[8px] bg-panelx overflow-hidden">
            <div className="flex items-center justify-between border-b border-linex bg-panel2x px-4 py-2.5 text-[10px]">
              <span className="text-dimx">~/Library/Application Support/Blink/config.json</span>
              <span className="text-faintx">jsonc · annotated</span>
            </div>
            <div className="overflow-x-auto p-4">
              <pre className="text-[11px] leading-[1.85] min-w-[540px]">
                {LINES.map((tokens, i) => (
                  <div key={i} className="flex">
                    <span className="w-7 shrink-0 select-none text-right pr-3 text-[var(--ghost)]">{i + 1}</span>
                    <span className="whitespace-pre">
                      {tokens.map(([t, c], j) => (
                        <span key={j} style={{ color: COLORS[c] }}>
                          {t}
                        </span>
                      ))}
                    </span>
                  </div>
                ))}
              </pre>
            </div>
            <div className="border-t border-linex px-4 py-2 text-[10px] text-faintx flex justify-between">
              <span>watching for changes…</span>
              <span className="text-acc">hot-apply &lt; 1s</span>
            </div>
          </div>

          {/* side notes */}
          <div className="space-y-3">
            {[
              {
                k: 'one source of truth',
                v: 'The GUI settings window reads and writes this file — no hidden state, no plist shadow copy.',
              },
              {
                k: 'scriptable by anything',
                v: 'Your dotfiles manager, an agent, a sed one-liner. If it can write a file, it can reconfigure Canvas.',
              },
              {
                k: 'atomic + watched',
                v: 'Edits are applied to every open panel in under a second, with the same reconcile path as note content.',
              },
              {
                k: 'git-friendly',
                v: 'Check it into your dotfiles repo. Diffable, reviewable, revertable — like everything else here.',
              },
            ].map((n, i) => (
              <div key={n.k} className="border border-linex rounded-[7px] bg-panelx px-4 py-3.5 flex gap-4">
                <span className="text-[10px] text-faintx pt-[3px] tabular-nums">{String(i + 1).padStart(2, '0')}</span>
                <div>
                  <div className="text-[12.5px] font-bold text-[var(--text)]">{n.k}</div>
                  <div className="mt-1 text-[11px] leading-[1.65] text-dimx">{n.v}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
