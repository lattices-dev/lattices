function ZapIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#ef6a47" strokeWidth="1.5"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" /></svg>
}
function ChartIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#ef6a47" strokeWidth="1.5"><rect x="3" y="12" width="4" height="9" rx="1" /><rect x="10" y="7" width="4" height="14" rx="1" /><rect x="17" y="3" width="4" height="18" rx="1" /></svg>
}
function CheckIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#ef6a47" strokeWidth="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" /><polyline points="22 4 12 14.01 9 11.01" /></svg>
}
function RefreshIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#ef6a47" strokeWidth="1.5"><polyline points="23 4 23 10 17 10" /><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" /></svg>
}

const stats = [
  { value: '~1s first', label: 'Response time', Icon: ZapIcon },
  { value: '~2,000', label: 'Context tokens', Icon: ChartIcon },
  { value: '97%', label: 'Test accuracy', Icon: CheckIcon },
  { value: '5', label: 'AI providers', Icon: RefreshIcon },
]

export default function StatsRow() {
  return (
    <div style={{
      margin: '32px 0',
      display: 'grid',
      gridTemplateColumns: 'repeat(4, 1fr)',
      gap: 12,
      fontFamily: "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
    }}>
      {stats.map(stat => (
        <div key={stat.label} style={{
          padding: '16px 14px',
          borderRadius: 10,
          border: '1px solid rgba(255,255,255,0.06)',
          background: 'rgba(255,255,255,0.02)',
          textAlign: 'center',
        }}>
          <div style={{ marginBottom: 8, display: 'flex', justifyContent: 'center' }}><stat.Icon /></div>
          <div style={{
            fontFamily: "'JetBrains Mono', monospace",
            fontSize: 17, fontWeight: 500, color: '#ef6a47',
            marginBottom: 4,
          }}>
            {stat.value}
          </div>
          <div style={{ fontSize: 11, fontWeight: 400, color: 'rgba(255,255,255,0.3)' }}>{stat.label}</div>
        </div>
      ))}
    </div>
  )
}
