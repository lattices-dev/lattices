'use client'

import { useEffect, useRef, useState } from 'react'

const THEMES = [
  { id: 'light', label: 'Light', detail: 'Parchment light' },
  { id: 'dark', label: 'Dark', detail: 'Neutral dark' },
  { id: 'auto', label: 'Auto', detail: 'Follow macOS' },
] as const

type ThemePreference = (typeof THEMES)[number]['id']

const SYSTEM_DARK_QUERY = '(prefers-color-scheme: dark)'

function normalize(raw: string | null): ThemePreference | null {
  if (raw === 'light' || raw === 'cream') return 'light'
  if (raw === 'dark' || raw === 'black') return 'dark'
  if (raw === 'auto') return 'auto'
  return null
}

function applyTheme(preference: ThemePreference, systemDark?: boolean) {
  const root = document.getElementById('blink-landing')!
  const dark =
    preference === 'dark' ||
    (preference === 'auto' &&
      (systemDark ?? window.matchMedia(SYSTEM_DARK_QUERY).matches))

  root.setAttribute('data-theme-preference', preference)
  if (dark) root.setAttribute('data-theme', 'black')
  else root.removeAttribute('data-theme')
}

function ThemeIcon({ id }: { id: ThemePreference }) {
  if (id === 'light') {
    return (
      <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden>
        <circle cx="8" cy="8" r="2.5" />
        <path d="M8 1.25v1.5M8 13.25v1.5M1.25 8h1.5M13.25 8h1.5M3.23 3.23l1.06 1.06M11.71 11.71l1.06 1.06M12.77 3.23l-1.06 1.06M4.29 11.71l-1.06 1.06" />
      </svg>
    )
  }

  if (id === 'dark') {
    return (
      <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden>
        <path d="M12.9 10.65A5.8 5.8 0 0 1 5.35 3.1 5.85 5.85 0 1 0 12.9 10.65Z" />
      </svg>
    )
  }

  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden>
      <rect x="2.25" y="3" width="11.5" height="8.25" rx="1.25" />
      <path d="M6 13.25h4M8 11.25v2" />
    </svg>
  )
}

export function ThemeSwitcher() {
  const [active, setActive] = useState<ThemePreference>('auto')
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([])

  useEffect(() => {
    const query = normalize(new URLSearchParams(window.location.search).get('theme'))
    const bootPreference = normalize(document.getElementById('blink-landing')!.getAttribute('data-theme-preference'))
    let saved: ThemePreference | null = null

    try {
      saved = normalize(localStorage.getItem('blink-theme'))
    } catch {
      saved = null
    }

    const preference = query ?? bootPreference ?? saved ?? 'auto'
    const media = window.matchMedia(SYSTEM_DARK_QUERY)

    queueMicrotask(() => setActive(preference))
    applyTheme(preference, media.matches)
    try {
      localStorage.setItem('blink-theme', preference)
    } catch {
      /* storage can be blocked */
    }

    const syncSystemTheme = (event: MediaQueryListEvent) => {
      if (document.getElementById('blink-landing')!.getAttribute('data-theme-preference') === 'auto') {
        applyTheme('auto', event.matches)
      }
    }
    const syncSavedTheme = (event: StorageEvent) => {
      if (event.key !== 'blink-theme') return
      const next = normalize(event.newValue) ?? 'auto'
      setActive(next)
      applyTheme(next, media.matches)
    }

    media.addEventListener('change', syncSystemTheme)
    window.addEventListener('storage', syncSavedTheme)
    return () => {
      media.removeEventListener('change', syncSystemTheme)
      window.removeEventListener('storage', syncSavedTheme)
    }
  }, [])

  const pick = (preference: ThemePreference) => {
    setActive(preference)
    applyTheme(preference)
    try {
      localStorage.setItem('blink-theme', preference)
      const url = new URL(window.location.href)
      url.searchParams.set('theme', preference)
      window.history.replaceState(window.history.state, '', url)
    } catch {
      /* storage or history can be blocked */
    }
  }

  const onKeyDown = (event: React.KeyboardEvent<HTMLButtonElement>, index: number) => {
    let nextIndex = index
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') nextIndex = (index + 1) % THEMES.length
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') nextIndex = (index - 1 + THEMES.length) % THEMES.length
    else if (event.key === 'Home') nextIndex = 0
    else if (event.key === 'End') nextIndex = THEMES.length - 1
    else return

    event.preventDefault()
    const next = THEMES[nextIndex].id
    pick(next)
    optionRefs.current[nextIndex]?.focus()
  }

  return (
    <div
      className="inline-flex h-8 items-center rounded-[6px] border border-line2x bg-panelx p-0.5"
      role="radiogroup"
      aria-label="Color theme"
    >
      {THEMES.map((theme, index) => {
        const selected = active === theme.id
        return (
          <button
            key={theme.id}
            ref={(element) => {
              optionRefs.current[index] = element
            }}
            type="button"
            role="radio"
            aria-checked={selected}
            aria-label={`${theme.label} theme — ${theme.detail}`}
            title={`${theme.label} — ${theme.detail}`}
            tabIndex={selected ? 0 : -1}
            onClick={() => pick(theme.id)}
            onKeyDown={(event) => onKeyDown(event, index)}
            className={[
              'inline-flex h-7 w-7 items-center justify-center rounded-[4px] transition-[color,background-color,box-shadow] duration-150',
              selected
                ? 'bg-[var(--acc-soft)] text-acc shadow-[inset_0_0_0_1px_rgba(var(--acc-rgb),0.28)]'
                : 'text-faintx hover:bg-[var(--acc-soft)] hover:text-[var(--text)]',
            ].join(' ')}
          >
            <ThemeIcon id={theme.id} />
          </button>
        )
      })}
    </div>
  )
}
