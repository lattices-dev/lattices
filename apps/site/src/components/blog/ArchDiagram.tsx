import { useState } from 'react'
import { ArcDiagram } from '@arach/arc'
import diagram from './handsoff-arch.diagram'

const ff = "-apple-system, BlinkMacSystemFont, 'Inter', sans-serif"

function ExpandIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><polyline points="15 3 21 3 21 9" /><polyline points="9 21 3 21 3 15" /><line x1="21" y1="3" x2="14" y2="10" /><line x1="3" y1="21" x2="10" y2="14" /></svg>
}

function CollapseIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><polyline points="4 14 10 14 10 20" /><polyline points="20 10 14 10 14 4" /><line x1="14" y1="10" x2="21" y2="3" /><line x1="3" y1="21" x2="10" y2="14" /></svg>
}

export default function HandsOffArch() {
  const [expanded, setExpanded] = useState(false)

  return (
    <div style={{
      margin: expanded ? '32px 0' : '32px 0',
      // Break out of the 720px prose column when expanded
      ...(expanded ? {
        marginLeft: 'calc(-50vw + 50%)',
        marginRight: 'calc(-50vw + 50%)',
        padding: '0 24px',
      } : {}),
      transition: 'all 0.3s ease',
    }}>
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        marginBottom: 12,
        // Keep label within readable width when expanded
        ...(expanded ? { maxWidth: 720, margin: '0 auto 12px' } : {}),
      }}>
        <span style={{
          fontSize: 12, fontWeight: 500, textTransform: 'uppercase',
          letterSpacing: '0.08em', color: '#ef6a47', fontFamily: ff,
        }}>
          System architecture
        </span>
        <button
          onClick={() => setExpanded(!expanded)}
          style={{
            display: 'flex', alignItems: 'center', gap: 5,
            padding: '4px 8px', borderRadius: 6,
            border: '1px solid rgba(255,255,255,0.08)',
            background: 'rgba(255,255,255,0.03)',
            color: 'rgba(255,255,255,0.35)',
            fontSize: 11, fontWeight: 400, fontFamily: ff,
            cursor: 'pointer', transition: 'all 0.15s',
          }}
          onMouseEnter={e => {
            e.currentTarget.style.borderColor = 'rgba(239,106,71,0.3)'
            e.currentTarget.style.color = '#ef6a47'
          }}
          onMouseLeave={e => {
            e.currentTarget.style.borderColor = 'rgba(255,255,255,0.08)'
            e.currentTarget.style.color = 'rgba(255,255,255,0.35)'
          }}
        >
          {expanded ? <CollapseIcon /> : <ExpandIcon />}
          {expanded ? 'Collapse' : 'Expand'}
        </button>
      </div>

      <div style={{
        borderRadius: 12,
        border: '1px solid rgba(255,255,255,0.06)',
        overflow: 'hidden',
        ...(expanded ? { maxWidth: 1200, margin: '0 auto' } : {}),
      }}>
        <ArcDiagram
          key={expanded ? 'expanded' : 'compact'}
          data={diagram}
          mode="dark"
          interactive={true}
          defaultZoom={expanded ? 'fit' : 0.75}
          showArcToggle={false}
        />
      </div>
    </div>
  )
}
