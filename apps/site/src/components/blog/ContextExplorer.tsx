import { useState } from 'react'

type ViewMode = 'before' | 'after'

const beforeSnapshot = [
  { app: 'iTerm2', title: 'Claude Code', position: '0,0 1440×900' },
  { app: 'iTerm2', title: 'Claude Code', position: '720,0 720×900' },
  { app: 'Google Chrome', title: 'GitHub — PR #42', position: '0,0 720×900' },
]

const afterSnapshot = {
  screens: [
    { name: 'Built-in', res: '1728×1117', primary: true },
    { name: 'LG UltraFine', res: '2560×1440', primary: false },
  ],
  windows: [
    {
      app: 'iTerm2', title: 'Claude Code', wid: 423,
      frame: '0,25 864×1092', screen: 1, zIndex: 0,
      terminal: { cwd: '~/dev/lattices', hasClaude: true, processes: ['claude', 'node'], tmux: 'lattices' },
    },
    {
      app: 'iTerm2', title: 'Claude Code', wid: 891,
      frame: '864,25 864×1092', screen: 1, zIndex: 1,
      terminal: { cwd: '~/dev/vox', hasClaude: true, processes: ['claude'], tmux: 'vox' },
    },
    {
      app: 'Google Chrome', title: 'GitHub — lattices PR #42', wid: 205,
      frame: '0,0 1280×900', screen: 2, zIndex: 2,
      terminal: null,
    },
    {
      app: 'Finder', title: 'Downloads', wid: 112,
      frame: '1280,0 1280×900', screen: 2, zIndex: 3,
      terminal: null,
    },
  ],
  layers: { active: 'L1', windows: [423, 891] },
}

export default function ContextExplorer() {
  const [view, setView] = useState<ViewMode>('after')

  return (
    <div style={{ margin: '32px 0', fontFamily: "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif" }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
        <span style={{ fontSize: 13, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.08em', color: '#ef6a47' }}>
          What the AI sees
        </span>
        <div style={{ display: 'flex', gap: 4, background: 'rgba(255,255,255,0.04)', borderRadius: 8, padding: 3, border: '1px solid rgba(255,255,255,0.06)' }}>
          {(['before', 'after'] as ViewMode[]).map(m => (
            <button
              key={m}
              onClick={() => setView(m)}
              style={{
                padding: '5px 12px', borderRadius: 6, border: 'none',
                background: view === m ? 'rgba(239,106,71,0.15)' : 'transparent',
                color: view === m ? '#ef6a47' : 'rgba(255,255,255,0.3)',
                fontSize: 12, fontWeight: 500, cursor: 'pointer',
                fontFamily: "'JetBrains Mono', monospace",
                transition: 'all 0.15s',
              }}
            >
              {m === 'before' ? 'v1 (basic)' : 'v2 (full)'}
            </button>
          ))}
        </div>
      </div>

      <div style={{
        borderRadius: 12,
        border: '1px solid rgba(255,255,255,0.06)',
        background: '#0d0d0f',
        overflow: 'hidden',
        fontFamily: "'JetBrains Mono', monospace",
        fontSize: 12,
      }}>
        {/* Header */}
        <div style={{
          padding: '8px 14px',
          borderBottom: '1px solid rgba(255,255,255,0.06)',
          background: 'rgba(255,255,255,0.02)',
          display: 'flex', alignItems: 'center', gap: 8,
          color: 'rgba(255,255,255,0.3)', fontSize: 11,
        }}>
          <span style={{ color: view === 'before' ? 'rgba(255,255,255,0.3)' : '#ef6a47' }}>●</span>
          {view === 'before' ? 'desktop-snapshot.json (v1)' : 'desktop-snapshot.json (v2)'}
          <span style={{ marginLeft: 'auto', fontSize: 10 }}>
            {view === 'before' ? '~200 tokens' : '~2,000 tokens'}
          </span>
        </div>

        {/* Content */}
        <div style={{ padding: '14px 16px', lineHeight: 1.7, color: 'rgba(255,255,255,0.5)' }}>
          {view === 'before' ? (
            <div>
              <div style={{ color: 'rgba(255,255,255,0.2)' }}>{'{'}</div>
              <div style={{ paddingLeft: 16 }}>
                <span style={{ color: '#7ec8e3' }}>"windows"</span>: [
                {beforeSnapshot.map((w, i) => (
                  <div key={i} style={{ paddingLeft: 16 }}>
                    {'{ '}
                    <span style={{ color: '#7ec8e3' }}>"app"</span>: <span style={{ color: '#ef6a47' }}>"{w.app}"</span>,{' '}
                    <span style={{ color: '#7ec8e3' }}>"title"</span>: <span style={{ color: '#ef6a47' }}>"{w.title}"</span>,{' '}
                    <span style={{ color: '#7ec8e3' }}>"position"</span>: <span style={{ color: '#ef6a47' }}>"{w.position}"</span>
                    {' }'}
                    {i < beforeSnapshot.length - 1 ? ',' : ''}
                  </div>
                ))}
                <div>]</div>
              </div>
              <div style={{ color: 'rgba(255,255,255,0.2)' }}>{'}'}</div>

              <div style={{
                marginTop: 14, padding: '8px 12px', borderRadius: 6,
                background: 'rgba(239,68,68,0.06)', border: '1px solid rgba(239,68,68,0.15)',
                color: '#ef4444', fontSize: 11,
              }}>
                Problem: Two windows both named "Claude Code" — which is which?
              </div>
            </div>
          ) : (
            <div>
              <div style={{ color: 'rgba(255,255,255,0.2)' }}>{'{'}</div>
              <div style={{ paddingLeft: 16 }}>
                {/* Screens */}
                <span style={{ color: '#7ec8e3' }}>"screens"</span>: [
                {afterSnapshot.screens.map((s, i) => (
                  <div key={i} style={{ paddingLeft: 16, color: 'rgba(255,255,255,0.35)' }}>
                    {'{ '}<span style={{ color: '#7ec8e3' }}>"name"</span>: <span style={{ color: '#ef6a47' }}>"{s.name}"</span>,
                    {' '}<span style={{ color: '#7ec8e3' }}>"res"</span>: <span style={{ color: '#ef6a47' }}>"{s.res}"</span>
                    {s.primary && <>, <span style={{ color: '#7ec8e3' }}>"primary"</span>: <span style={{ color: '#f5a623' }}>true</span></>}
                    {' }'}
                  </div>
                ))}
                <div>],</div>

                {/* Windows with terminal enrichment */}
                <span style={{ color: '#7ec8e3' }}>"windows"</span>: [
                {afterSnapshot.windows.map((w, i) => (
                  <div key={i} style={{ paddingLeft: 16, marginTop: 4 }}>
                    <div style={{ color: 'rgba(255,255,255,0.35)' }}>
                      {'{ '}
                      <span style={{ color: '#7ec8e3' }}>"app"</span>: <span style={{ color: '#ef6a47' }}>"{w.app}"</span>,
                      {' '}<span style={{ color: '#7ec8e3' }}>"z"</span>: <span style={{ color: '#f5a623' }}>{w.zIndex}</span>,
                      {' '}<span style={{ color: '#7ec8e3' }}>"screen"</span>: <span style={{ color: '#f5a623' }}>{w.screen}</span>,
                    </div>
                    {w.terminal && (
                      <div style={{ paddingLeft: 16, color: 'rgba(255,255,255,0.35)' }}>
                        <span style={{ color: '#c792ea' }}>// terminal enrichment</span>
                        <br />
                        <span style={{ color: '#7ec8e3' }}>"cwd"</span>: <span style={{ color: '#ef6a47' }}>"{w.terminal.cwd}"</span>,
                        {' '}<span style={{ color: '#7ec8e3' }}>"hasClaude"</span>: <span style={{ color: '#f5a623' }}>true</span>,
                        {' '}<span style={{ color: '#7ec8e3' }}>"tmux"</span>: <span style={{ color: '#ef6a47' }}>"{w.terminal.tmux}"</span>
                      </div>
                    )}
                    <div style={{ color: 'rgba(255,255,255,0.35)' }}>
                      {'}'}{i < afterSnapshot.windows.length - 1 ? ',' : ''}
                    </div>
                  </div>
                ))}
                <div>],</div>

                {/* Layer */}
                <span style={{ color: '#7ec8e3' }}>"activeLayer"</span>: <span style={{ color: '#ef6a47' }}>"L1"</span>
              </div>
              <div style={{ color: 'rgba(255,255,255,0.2)' }}>{'}'}</div>

              <div style={{
                marginTop: 14, padding: '8px 12px', borderRadius: 6,
                background: 'rgba(239,106,71,0.06)', border: '1px solid rgba(239,106,71,0.15)',
                color: '#ef6a47', fontSize: 11,
              }}>
                "Focus on the lattices Claude Code" → correctly picks wid 423 (cwd: ~/dev/lattices)
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
