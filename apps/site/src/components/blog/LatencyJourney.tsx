import { useState } from 'react'

const ff = "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif"
const mono = "'JetBrains Mono', monospace"

const iterations = [
  {
    id: 1, label: 'Naive approach', time: 7000, timeLabel: '~7s', color: '#ef4444',
    detail: 'Separate process per call, synchronous TTS download, no caching. Functional but sluggish. User waits with no feedback.',
    fix: null, saved: null,
  },
  {
    id: 2, label: 'Direct API (Vercel AI SDK)', time: 3500, timeLabel: '~3.5s', color: '#f59e0b',
    detail: 'One fetch call to Groq running Llama 3.3 70B via the Vercel AI SDK. Thin inference wrapper, ~150 lines. Swappable providers.',
    fix: 'CLI shell-out \u2192 direct API call', saved: '-3.5s',
  },
  {
    id: 3, label: 'Long-running worker', time: 2500, timeLabel: '~2.5s', color: '#f59e0b',
    detail: 'One persistent bun process stays alive between turns. Reads JSON from stdin, keeps clients and prompts warm. Zero cold starts.',
    fix: 'Fork-per-call \u2192 persistent process', saved: '-1s',
  },
  {
    id: 4, label: 'Streaming TTS', time: 2000, timeLabel: '~1s to first audio', color: '#22c55e',
    detail: 'Stream OpenAI TTS response body directly into ffplay via stdin pipe. PCM format, no decoding. Playback starts on first chunk.',
    fix: 'Download-then-play \u2192 stream-to-pipe', saved: '-0.5s',
  },
  {
    id: 5, label: 'Pre-cached phrases', time: 50, timeLabel: '<50ms ack', color: '#22c55e',
    detail: '17 stock phrases generated on startup, cached as PCM files. Instant playback, zero network.',
    fix: 'API call \u2192 disk read', saved: '-2s on ack',
  },
  {
    id: 6, label: 'Speak first, then act', time: 2000, timeLabel: '~2s e2e', color: '#33c773',
    detail: 'Narrate the plan before executing. First response in ~1s, windows move at ~2s. The user is never surprised.',
    fix: 'Silent action \u2192 narrate-then-act', saved: 'UX win',
  },
]

const maxTime = 7000

export default function LatencyJourney() {
  const [active, setActive] = useState<number | null>(null)

  return (
    <div style={{ margin: '32px 0', fontFamily: ff }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 20 }}>
        <span style={{ fontSize: 12, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.08em', color: '#ef6a47' }}>
          Performance journey
        </span>
        <span style={{ fontSize: 11, fontWeight: 400, color: 'rgba(255,255,255,0.2)' }}>Click to explore</span>
      </div>

      <div style={{ display: 'grid', gap: 4 }}>
        {iterations.map((iter) => {
          const isActive = active === iter.id
          const barWidth = Math.max(2, (iter.time / maxTime) * 100)

          return (
            <div
              key={iter.id}
              onClick={() => setActive(isActive ? null : iter.id)}
              style={{
                padding: '10px 14px', borderRadius: 8,
                border: `1px solid ${isActive ? 'rgba(239,106,71,0.2)' : 'rgba(255,255,255,0.03)'}`,
                background: isActive ? 'rgba(239,106,71,0.03)' : 'transparent',
                cursor: 'pointer', transition: 'all 0.2s',
              }}
            >
              {/* Header row */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
                <span style={{
                  width: 18, height: 18, borderRadius: '50%',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 9, fontWeight: 500,
                  background: `${iter.color}12`, color: iter.color,
                  border: `1px solid ${iter.color}25`, flexShrink: 0,
                }}>
                  {iter.id}
                </span>
                <span style={{ fontSize: 13, fontWeight: 400, color: 'rgba(255,255,255,0.65)', flex: 1 }}>
                  {iter.label}
                </span>
                {iter.saved && (
                  <span style={{
                    fontSize: 10, fontWeight: 400, fontFamily: mono,
                    color: 'rgba(239,106,71,0.6)',
                    padding: '1px 5px', borderRadius: 3,
                    background: 'rgba(239,106,71,0.06)',
                  }}>
                    {iter.saved}
                  </span>
                )}
                <span style={{ fontFamily: mono, fontSize: 12, fontWeight: 400, color: iter.color, minWidth: 80, textAlign: 'right' }}>
                  {iter.timeLabel}
                </span>
              </div>

              {/* Bar — log scale */}
              <div style={{ height: 3, borderRadius: 2, background: 'rgba(255,255,255,0.025)', overflow: 'hidden' }}>
                <div style={{
                  height: '100%', borderRadius: 2,
                  width: `${barWidth}%`,
                  background: `linear-gradient(90deg, ${iter.color}cc, ${iter.color}33)`,
                  transition: 'width 0.5s ease',
                }} />
              </div>

              {/* Expanded detail */}
              {isActive && (
                <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px solid rgba(255,255,255,0.04)' }}>
                  <p style={{ fontSize: 12, fontWeight: 400, color: 'rgba(255,255,255,0.4)', lineHeight: 1.6, margin: 0 }}>
                    {iter.detail}
                  </p>
                  {iter.fix && (
                    <div style={{
                      marginTop: 8, display: 'inline-flex', alignItems: 'center', gap: 6,
                      padding: '3px 8px', borderRadius: 5,
                      background: 'rgba(239,106,71,0.05)', border: '1px solid rgba(239,106,71,0.1)',
                      fontSize: 11, fontWeight: 400, color: '#ef6a47', fontFamily: mono,
                    }}>
                      {iter.fix}
                    </div>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>

      {/* Summary */}
      <div style={{
        marginTop: 10, padding: '10px 14px', borderRadius: 8,
        background: 'rgba(239,106,71,0.03)', border: '1px solid rgba(239,106,71,0.08)',
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      }}>
        <span style={{ fontSize: 12, fontWeight: 400, color: 'rgba(255,255,255,0.35)' }}>Total improvement</span>
        <span style={{ fontFamily: mono, fontSize: 13, fontWeight: 400, color: '#ef6a47' }}>
          ~7s {'→'} ~2s{'  '}
          <span style={{ color: 'rgba(239,106,71,0.5)', fontSize: 11 }}>(first response at ~1s)</span>
        </span>
      </div>
    </div>
  )
}
