import { MockTitleBar, Reveal, SectionHeader } from './shared'

const DOCS = [
  {
    href: '/llms.txt',
    label: 'llms.txt',
    detail: 'product map + canonical links',
  },
  {
    href: '/agents.md',
    label: 'agents.md',
    detail: 'complete operating contract',
  },
  {
    href: 'https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/cli.md',
    label: 'CLI reference',
    detail: 'commands + JSON shapes',
  },
]

const CONTRACT = [
  {
    term: 'Use the CLI',
    detail: 'Prefer blink over GUI automation. It handles slugs, atomic writes, stdin, and structured output.',
  },
  {
    term: 'Files are truth',
    detail: 'Every note is one Markdown file. Metadata and portable placement intent travel in YAML frontmatter.',
  },
  {
    term: 'Choose the verb',
    detail: 'present creates or composes; type adds a visible update; write quietly replaces; cat and search read.',
  },
  {
    term: 'App optional',
    detail: 'Writes still land while Canvas is closed. The app reconciles them when it is running or next opens.',
  },
  {
    term: 'Configure by file',
    detail: 'Edit ~/Library/Application Support/Blink/config.json for behavior, appearance, styles, and workspaces. Valid changes hot-apply.',
  },
]

export default function AgentGuide() {
  return (
    <section id="agents" className="scroll-mt-16 border-t border-linex py-20 md:py-28">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <SectionHeader
          tag="FOR AGENTS"
          title={
            <>
              The whole operating contract, <span className="text-acc">without the GUI.</span>
            </>
          }
          sub="Install once, use predictable verbs, and drop to plain Markdown whenever the abstraction gets in the way. These are the stable entry points an agent can discover and act on."
        />

        <Reveal>
          <nav
            aria-label="Agent documentation"
            className="grid border-y border-linex sm:grid-cols-3"
          >
            {DOCS.map((doc, index) => (
              <a
                key={doc.href}
                href={doc.href}
                target="_blank"
                rel="noreferrer"
                className={[
                  'group flex min-w-0 items-center justify-between gap-4 py-4 transition-colors hover:bg-[var(--acc-soft)] focus-visible:bg-[var(--acc-soft)]',
                  index > 0 ? 'border-t border-linex sm:border-l sm:border-t-0' : '',
                  index === 0 ? 'sm:pr-5' : 'sm:px-5',
                  index === DOCS.length - 1 ? 'sm:pr-0' : '',
                ]
                  .filter(Boolean)
                  .join(' ')}
              >
                <span className="min-w-0">
                  <span className="block text-[12.5px] font-bold text-[var(--text)]">{doc.label}</span>
                  <span className="mt-1 block text-[10.5px] leading-[1.5] text-faintx">{doc.detail}</span>
                </span>
                <span className="shrink-0 text-[14px] text-faintx transition-transform group-hover:translate-x-0.5" aria-hidden>
                  ↗
                </span>
              </a>
            ))}
          </nav>

          <div className="mt-8 grid items-start gap-8 lg:grid-cols-[1.05fr_0.95fr] lg:gap-12">
            <div className="overflow-hidden rounded-[8px] border border-linex bg-panelx">
              <MockTitleBar
                title="zero → spatial note"
                trailing={<span className="text-faintx">macOS 14+ · arm64</span>}
              />
              <div className="p-4 md:p-5">
                <pre className="whitespace-pre-wrap break-words text-[11.5px] leading-[1.9] text-dimx">
                  <code>{`npm install -g @arach/blink
blink app install
blink app open

blink present q3-plan $'# Q3 plan\\n\\nShip it.' \\
  --slot 6 --style focus --json`}</code>
                </pre>
              </div>
              <div className="border-t border-linex px-4 py-3 text-[10.5px] leading-[1.6] text-faintx md:px-5">
                <span className="text-dimx">notes → </span>
                <span className="break-all">~/Library/Application Support/Blink/Notes/</span>
              </div>
            </div>

            <dl className="border-t border-linex">
              {CONTRACT.map((item) => (
                <div key={item.term} className="grid gap-1 border-b border-linex py-4 sm:grid-cols-[8.5rem_1fr] sm:gap-5">
                  <dt className="text-[11.5px] font-bold text-[var(--text)]">{item.term}</dt>
                  <dd className="text-[11px] leading-[1.65] text-dimx">{item.detail}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div className="mt-6 flex flex-col gap-2 text-[10.5px] leading-[1.65] text-faintx sm:flex-row sm:items-center sm:justify-between">
            <span>
              Core verbs: <span className="text-dimx">ls · cat · new · present · type · write · search · rm · path · workspace</span>
            </span>
            <span>
              Sandbox with <span className="text-dimx">BLINK_HOME</span>
            </span>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
