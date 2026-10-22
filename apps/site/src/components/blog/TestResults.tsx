import { useState } from 'react'

interface Category {
  name: string
  score: number
  checks: number
  color: string
  examples: string[]
}

const categories: Category[] = [
  { name: 'Awareness', score: 100, checks: 30, color: '#33c773', examples: ['"What\'s on my screen?" → lists all visible windows', '"Is Chrome open?" → checks running apps'] },
  { name: 'Tiling', score: 100, checks: 36, color: '#33c773', examples: ['"Tile Chrome left" → correct position + window', '"Put terminal bottom-right" → quarter tile'] },
  { name: 'Layouts', score: 100, checks: 30, color: '#33c773', examples: ['"Side by side: Chrome + iTerm" → 50/50 split', '"Code review setup" → PR left, terminal right'] },
  { name: 'Focus', score: 96, checks: 24, color: '#22c55e', examples: ['"Focus on lattices" → picks correct terminal by cwd', '"Switch to Chrome" → finds and raises Chrome'] },
  { name: 'Context', score: 94, checks: 18, color: '#22c55e', examples: ['"The other terminal" → remembers previous action', '"Put that one on the right" → uses conversation history'] },
  { name: 'Intelligence', score: 100, checks: 30, color: '#33c773', examples: ['"Organize my terminals" → distributes in grid', '"Clean up" → suggests layouts based on window count'] },
  { name: 'Error handling', score: 67, checks: 12, color: '#ef4444', examples: ['"Open Photoshop" → says it can\'t launch apps (but still sends action)', 'Known issue: model sends actions for non-running apps'] },
  { name: 'Speech quality', score: 100, checks: 22, color: '#33c773', examples: ['"No window IDs in speech" → uses natural descriptions', '"Concise narration" → under 15 words per action'] },
]

const totalChecks = categories.reduce((sum, c) => sum + c.checks, 0)
const totalPassing = categories.reduce((sum, c) => sum + Math.round(c.checks * c.score / 100), 0)
const overallScore = Math.round((totalPassing / totalChecks) * 100)

export default function TestResults() {
  const [expanded, setExpanded] = useState<string | null>(null)

  return (
    <div style={{ margin: '32px 0', fontFamily: "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif" }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 20 }}>
        <span style={{ fontSize: 13, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.08em', color: '#ef6a47' }}>
          Test results
        </span>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontFamily: "'JetBrains Mono', monospace", fontSize: 24, fontWeight: 500, color: '#ef6a47' }}>{overallScore}%</span>
          <span style={{ fontSize: 12, color: 'rgba(255,255,255,0.25)' }}>{totalPassing}/{totalChecks} checks</span>
        </div>
      </div>

      <div style={{ display: 'grid', gap: 6 }}>
        {categories.map(cat => {
          const isExpanded = expanded === cat.name
          const passing = Math.round(cat.checks * cat.score / 100)

          return (
            <div
              key={cat.name}
              onClick={() => setExpanded(isExpanded ? null : cat.name)}
              style={{
                padding: '10px 14px',
                borderRadius: 8,
                border: `1px solid ${isExpanded ? `${cat.color}30` : 'rgba(255,255,255,0.04)'}`,
                background: isExpanded ? `${cat.color}06` : 'transparent',
                cursor: 'pointer',
                transition: 'all 0.15s',
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <span style={{ fontSize: 13, fontWeight: 500, color: 'rgba(255,255,255,0.7)', width: 120, flexShrink: 0 }}>
                  {cat.name}
                </span>

                {/* Bar */}
                <div style={{ flex: 1, height: 8, borderRadius: 4, background: 'rgba(255,255,255,0.04)', overflow: 'hidden' }}>
                  <div style={{
                    height: '100%', borderRadius: 4,
                    width: `${cat.score}%`,
                    background: cat.color,
                    transition: 'width 0.5s ease',
                  }} />
                </div>

                <span style={{
                  fontFamily: "'JetBrains Mono', monospace",
                  fontSize: 12, fontWeight: 500, color: cat.color,
                  width: 40, textAlign: 'right',
                }}>
                  {cat.score}%
                </span>
                <span style={{
                  fontSize: 11, color: 'rgba(255,255,255,0.2)',
                  width: 30, textAlign: 'right',
                }}>
                  {passing}/{cat.checks}
                </span>
              </div>

              {isExpanded && (
                <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px solid rgba(255,255,255,0.05)' }}>
                  {cat.examples.map((ex, i) => (
                    <div key={i} style={{
                      fontSize: 12, color: 'rgba(255,255,255,0.4)', lineHeight: 1.6,
                      paddingLeft: 12, borderLeft: `2px solid ${cat.color}30`,
                      marginBottom: i < cat.examples.length - 1 ? 8 : 0,
                    }}>
                      {ex}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
