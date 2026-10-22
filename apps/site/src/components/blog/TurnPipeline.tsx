import { useState, type ReactNode } from 'react'

const ff = "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif"
const mono = "'JetBrains Mono', monospace"

// SVG icons as components (thin line style)
function KeyIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4" /></svg> }
function MicIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" /><path d="M19 10v2a7 7 0 0 1-14 0v-2" /><line x1="12" y1="19" x2="12" y2="23" /><line x1="8" y1="23" x2="16" y2="23" /></svg> }
function VolumeIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" /><path d="M15.54 8.46a5 5 0 0 1 0 7.07" /></svg> }
function CpuIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="4" y="4" width="16" height="16" rx="2" /><rect x="9" y="9" width="6" height="6" /><line x1="9" y1="1" x2="9" y2="4" /><line x1="15" y1="1" x2="15" y2="4" /><line x1="9" y1="20" x2="9" y2="23" /><line x1="15" y1="20" x2="15" y2="23" /><line x1="20" y1="9" x2="23" y2="9" /><line x1="20" y1="14" x2="23" y2="14" /><line x1="1" y1="9" x2="4" y2="9" /><line x1="1" y1="14" x2="4" y2="14" /></svg> }
function MessageIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg> }
function ZapIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" /></svg> }
function CheckCircleIcon() { return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" /><polyline points="22 4 12 14.01 9 11.01" /></svg> }

interface Stage {
  id: string
  label: string
  time: string
  Icon: () => ReactNode
  color: string
  detail: string
  parallel?: string
  link?: string
}

const stages: Stage[] = [
  { id: 'hotkey', label: 'Hotkey', time: '0ms', Icon: KeyIcon, color: '#a78bfa', detail: 'Ctrl+Cmd+M activates push-to-talk. Vox begins streaming audio for transcription.' },
  { id: 'vox', label: 'Vox (STT)', time: '~400ms', Icon: MicIcon, color: '#60a5fa', detail: 'Speech-to-text via Vox. Fast transcription streams as the user speaks.', link: 'https://usevox.dev' },
  { id: 'ack', label: 'Ack sound', time: '<50ms', Icon: VolumeIcon, color: '#34d399', detail: 'Pre-cached PCM audio plays instantly from disk. No API call needed.', parallel: 'Plays while LLM thinks' },
  { id: 'llm', label: 'LLM inference', time: '500–1200ms', Icon: CpuIcon, color: '#f59e0b', detail: 'Full desktop snapshot + transcript sent to Grok. Returns structured JSON with spoken text and window actions.' },
  { id: 'tts', label: 'TTS narration', time: '~1s start', Icon: MessageIcon, color: '#33c773', detail: 'OpenAI TTS streams PCM audio directly into ffplay. User hears the plan before windows move.' },
  { id: 'act', label: 'Execute', time: '<1ms', Icon: ZapIcon, color: '#33c773', detail: 'Actions sent to Swift via stdout JSON. AX API calls tile/focus windows. Effectively instant.' },
  { id: 'done', label: 'Done', time: '<50ms', Icon: CheckCircleIcon, color: '#33c773', detail: 'Cached confirmation sound. Total: ~3s from speech to windows arranged.' },
]

export default function TurnPipeline() {
  const [hovered, setHovered] = useState<string | null>(null)

  return (
    <div style={{ margin: '32px 0', fontFamily: ff }}>
      <div style={{ fontSize: 12, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.08em', color: '#ef6a47', marginBottom: 20 }}>
        Anatomy of a voice turn
      </div>

      <div style={{ position: 'relative' }}>
        <div style={{ position: 'absolute', left: 19, top: 20, bottom: 20, width: 1, background: 'rgba(255,255,255,0.05)', zIndex: 0 }} />

        <div style={{ display: 'grid', gap: 2, position: 'relative', zIndex: 1 }}>
          {stages.map((stage) => {
            const isHovered = hovered === stage.id
            return (
              <div
                key={stage.id}
                onMouseEnter={() => setHovered(stage.id)}
                onMouseLeave={() => setHovered(null)}
                style={{
                  display: 'grid', gridTemplateColumns: '38px 1fr auto',
                  alignItems: 'center', gap: 12,
                  padding: '8px 12px 8px 0', borderRadius: 10,
                  background: isHovered ? 'rgba(255,255,255,0.02)' : 'transparent',
                  transition: 'all 0.15s', cursor: 'default',
                }}
              >
                <div style={{
                  width: 38, height: 38, borderRadius: '50%',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  color: isHovered ? stage.color : 'rgba(255,255,255,0.3)',
                  background: isHovered ? `${stage.color}10` : 'rgba(255,255,255,0.02)',
                  border: `1.5px solid ${isHovered ? `${stage.color}50` : 'rgba(255,255,255,0.06)'}`,
                  transition: 'all 0.2s',
                }}>
                  <stage.Icon />
                </div>

                <div>
                  <div style={{ fontSize: 13, fontWeight: 400, color: isHovered ? 'rgba(255,255,255,0.9)' : 'rgba(255,255,255,0.6)', transition: 'color 0.15s' }}>
                    {stage.link ? (
                      <a href={stage.link} target="_blank" rel="noopener noreferrer" style={{ color: 'inherit', textDecoration: 'none', borderBottom: '1px solid rgba(96,165,250,0.3)' }} onClick={e => e.stopPropagation()}>
                        {stage.label}
                      </a>
                    ) : stage.label}
                    {stage.parallel && (
                      <span style={{
                        marginLeft: 8, fontSize: 10, fontWeight: 400, padding: '1px 6px',
                        borderRadius: 4, background: 'rgba(245,166,35,0.08)',
                        color: '#f59e0b', border: '1px solid rgba(245,166,35,0.15)',
                      }}>
                        parallel
                      </span>
                    )}
                  </div>
                  {isHovered && (
                    <div style={{ fontSize: 11, fontWeight: 400, color: 'rgba(255,255,255,0.35)', lineHeight: 1.5, marginTop: 3, maxWidth: 400 }}>
                      {stage.detail}
                    </div>
                  )}
                </div>

                <div style={{
                  fontFamily: mono, fontSize: 11, fontWeight: 400,
                  color: isHovered ? stage.color : 'rgba(255,255,255,0.2)',
                  transition: 'color 0.15s', textAlign: 'right', whiteSpace: 'nowrap',
                }}>
                  {stage.time}
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* Timeline bar */}
      <div style={{
        marginTop: 20, height: 28, borderRadius: 8,
        background: 'rgba(255,255,255,0.02)', border: '1px solid rgba(255,255,255,0.05)',
        display: 'flex', overflow: 'hidden',
        fontSize: 9, fontFamily: mono, fontWeight: 400,
      }}>
        <div style={{ width: '16%', background: 'rgba(96,165,250,0.06)', borderRight: '1px solid rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#60a5fa' }}>vox 500ms</div>
        <div style={{ width: '2%', background: 'rgba(52,211,153,0.06)', borderRight: '1px solid rgba(255,255,255,0.04)' }} />
        <div style={{ width: '30%', background: 'rgba(245,158,11,0.06)', borderRight: '1px solid rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#f59e0b' }}>{'LLM 500–1200ms'}</div>
        <div style={{ width: '46%', background: 'rgba(51,199,115,0.05)', borderRight: '1px solid rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#33c773' }}>TTS stream + act ~1.5s</div>
        <div style={{ width: '6%', background: 'rgba(51,199,115,0.1)' }} />
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 5, fontSize: 9, fontWeight: 400, color: 'rgba(255,255,255,0.15)', fontFamily: mono }}>
        <span>0s</span>
        <span>feedback at ~500ms</span>
        <span>windows move at ~3s</span>
      </div>
    </div>
  )
}
