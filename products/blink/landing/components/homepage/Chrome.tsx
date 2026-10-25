import { ThemeSwitcher } from './ThemeSwitcher'
import { BlinkMark } from './BlinkMark'

const LINKS = [
  { href: '#how', label: 'how' },
  { href: '#agents', label: 'agents' },
  { href: '#desk', label: 'desk' },
  { href: '#keys', label: 'keys' },
  { href: '#install', label: 'install' },
]

export function TopBar() {
  return (
    <header className="fixed top-0 inset-x-0 z-50 border-b border-linex bg-[rgba(var(--bg-rgb),0.82)] backdrop-blur-md">
      <div className="mx-auto flex h-12 max-w-5xl items-center gap-3 px-4 md:gap-4 md:px-6">
        <a
          href="#top"
          className="font-display flex shrink-0 items-center gap-2 text-[17px] font-semibold leading-none tracking-[-0.015em] text-[var(--text)]"
        >
          <BlinkMark className="h-4 w-4 shrink-0 text-acc" />
          <span>Canvas</span>
        </a>

        <nav
          className="hidden min-w-0 flex-1 items-center justify-center gap-1 sm:flex md:gap-0.5"
          aria-label="Page"
        >
          {LINKS.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className="rounded-[4px] px-2.5 py-1.5 text-[11px] text-dimx transition-colors hover:bg-[var(--acc-soft)] hover:text-acc"
            >
              {l.label}
            </a>
          ))}
        </nav>

        <div className="ml-auto flex shrink-0 items-center gap-2">
          <ThemeSwitcher />
          <a
            href="https://github.com/lattices-dev/lattices/tree/main/products/blink"
            target="_blank"
            rel="noreferrer"
            aria-label="GitHub repository"
            className="inline-flex h-8 items-center justify-center gap-1.5 rounded-[6px] border border-line2x bg-panelx px-2 text-[11px] text-dimx transition-colors hover:border-[var(--line-2)] hover:bg-panel2x hover:text-[var(--text)] min-[380px]:px-2.5"
          >
            <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 shrink-0 fill-current" aria-hidden>
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
            </svg>
            <span className="hidden min-[380px]:inline">github</span>
          </a>
        </div>
      </div>
    </header>
  )
}
