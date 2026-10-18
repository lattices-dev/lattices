import { SectionHeader, PrimaryButton, GhostButton, Reveal, MockTitleBar } from './shared'

/** Blink's own references, which the family footer doesn't carry. */
const RELEASE_LINKS = [
  { href: 'https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/cli.md', label: 'CLI docs', external: true },
  { href: '/blink/llms.txt', label: 'llms.txt', external: false },
  { href: '/blink/agents.md', label: 'AGENTS.md', external: false },
  { href: 'https://blink.arach.dev/privacy/', label: 'Privacy', external: true },
] as const

export function Install() {
  return (
    <section id="install" className="scroll-mt-16 py-20 md:py-28 border-t border-linex">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <SectionHeader
          tag="INSTALL"
          title={
            <>
              Free, open source, <span className="text-acc">and yours</span>.
            </>
          }
          sub="A single native app for macOS. No account — download it, press Hyper+N, and start."
        />

        <Reveal>
          <div className="corner-frame">
            <div className="overflow-hidden rounded-[8px] border border-linex bg-panelx">
              <MockTitleBar title="release — latest" />
              <div className="flex flex-col gap-6 p-5 md:flex-row md:items-center md:justify-between md:gap-8 md:p-6">
                <div className="min-w-0">
                  <div className="text-[15px] font-bold text-[var(--text)]">Blink.dmg</div>
                  <div className="mt-1 text-[11px] text-faintx">
                    Apple Silicon · macOS 14+ · notarized · no account
                  </div>
                </div>
                <div className="flex flex-wrap gap-3 shrink-0">
                  <PrimaryButton href="/blink/download">
                    <span className="text-[15px] leading-none" aria-hidden>
                      ↓
                    </span>{' '}
                    download for macOS
                  </PrimaryButton>
                  <GhostButton href="https://github.com/lattices-dev/lattices/tree/main/products/blink">
                    source <span className="text-faintx" aria-hidden>↗</span>
                  </GhostButton>
                </div>
              </div>
            </div>
          </div>
          <ul className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-[11px] text-dimx">
            {RELEASE_LINKS.map((link) => (
              <li key={link.href}>
                <a
                  href={link.href}
                  {...(link.external ? { target: '_blank', rel: 'noreferrer' } : {})}
                  className="rounded-[3px] py-0.5 transition-colors hover:text-acc"
                >
                  {link.label}
                  {link.external && <span className="text-faintx" aria-hidden> ↗</span>}
                </a>
              </li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  )
}
