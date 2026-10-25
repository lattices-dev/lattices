import { SectionHeader, PrimaryButton, GhostButton, Reveal, MockTitleBar } from './shared'
import { BlinkMark } from './BlinkMark'

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
                  <div className="text-[15px] font-bold text-[var(--text)]">Canvas.dmg</div>
                  <div className="mt-1 text-[11px] text-faintx">
                    Apple Silicon · macOS 14+ · notarized · no account
                  </div>
                </div>
                <div className="flex flex-wrap gap-3 shrink-0">
                  <PrimaryButton href="https://github.com/lattices-dev/lattices/releases/download/canvas-v2.3.0/Canvas.dmg">
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
        </Reveal>
      </div>
    </section>
  )
}

const FOOTER_LINKS = [
  { href: 'https://github.com/lattices-dev/lattices/tree/main/products/blink', label: 'GitHub', external: true },
  { href: 'https://github.com/lattices-dev/lattices/releases/tag/canvas-v2.3.0', label: 'Releases', external: true },
  { href: '/agents.md', label: 'AGENTS.md', external: false },
  { href: '/llms.txt', label: 'llms.txt', external: false },
  { href: '/privacy/', label: 'Privacy', external: false },
  { href: '/support/', label: 'Support', external: false },
  {
    href: 'https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/cli.md',
    label: 'CLI docs',
    external: true,
  },
] as const

export function Footer() {
  return (
    <footer className="border-t border-linex pb-12 pt-8">
      <div className="mx-auto max-w-5xl px-4 md:px-6">
        <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between sm:gap-8">
          <div className="min-w-0">
            <div className="flex items-center gap-2 text-[12px] font-bold text-[var(--text)]">
              <BlinkMark className="h-4 w-4 shrink-0 text-acc" />
              <span>Canvas</span>
            </div>
            <p className="mt-1.5 text-[11px] leading-relaxed text-faintx">
              spatial notes for your Mac · formerly Blink
            </p>
          </div>

          <nav
            aria-label="Footer"
            className="flex flex-wrap items-center gap-x-4 gap-y-2 text-[11px] text-dimx sm:justify-end sm:max-w-md"
          >
            {FOOTER_LINKS.map((link) => (
              <a
                key={link.href}
                href={link.href}
                {...(link.external
                  ? { target: '_blank', rel: 'noreferrer' }
                  : {})}
                className="rounded-[3px] py-0.5 transition-colors hover:text-acc"
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>
        <div className="mt-6 flex flex-wrap items-center justify-between gap-2 text-[10px] text-[var(--ghost)]">
          <span>JetBrains Mono</span>
          <span>blink.arach.dev</span>
        </div>
      </div>
    </footer>
  )
}
