import { useId, useState, type FormEvent } from 'react'
import { accessPaths } from '../lib/access-paths'
import '../styles/email-access.css'

export function EmailAccess({ onUnlock }: { onUnlock: () => void }) {
  const id = useId()
  const [step, setStep] = useState<'email' | 'code'>('email')
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [sent, setSent] = useState(false)
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    setError('')
    try {
      const response = await fetch(step === 'email' ? accessPaths.welcome : accessPaths.unlock, {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(step === 'email' ? { email } : { code }),
      })
      const result = await response.json().catch(() => null)
      if (!response.ok) throw new Error(result?.error || 'Access is temporarily unavailable. Please try again shortly.')
      if (step === 'email') { setSent(true); setStep('code') }
      else onUnlock()
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Please try again shortly.') }
    finally { setBusy(false) }
  }
  return (
    <section className="email-access" aria-labelledby={`${id}-title`} data-pagefind-ignore>
      <h2 id={`${id}-title`}>Keep exploring.</h2>
      <p>Get free access to the full guides and studies. We’ll email you a welcome note with your access code.</p>
      {sent && <p className="email-access-sent" role="status">Your code is on its way to <strong>{email}</strong>. Check your inbox, then enter it below.</p>}
      <form onSubmit={submit} aria-busy={busy}>
        <label htmlFor={`${id}-input`}>{step === 'email' ? 'Email address' : 'Access code'}</label>
        <div className="email-access-fields">
          {step === 'email'
            ? <input id={`${id}-input`} type="email" autoComplete="email" placeholder="you@example.com" value={email} onChange={(event) => setEmail(event.target.value)} required maxLength={254} disabled={busy} aria-describedby={error ? `${id}-error` : undefined} />
            : <input key="code" id={`${id}-input`} type="text" autoComplete="one-time-code" autoCapitalize="characters" spellCheck={false} placeholder="Access code from your email" value={code} onChange={(event) => setCode(event.target.value)} required maxLength={32} disabled={busy} aria-describedby={error ? `${id}-error` : undefined} />}
          <button type="submit" disabled={busy}>{busy ? (step === 'email' ? 'Sending…' : 'Opening…') : step === 'email' ? 'Email my code' : 'Continue reading'}</button>
        </div>
        {error && <p className="email-access-error" id={`${id}-error`} role="alert">{error}</p>}
      </form>
      <div className="email-access-foot">
        <span>Free. No account or password.</span>
        <button type="button" disabled={busy} onClick={() => { setStep(step === 'email' ? 'code' : 'email'); setError('') }}>{step === 'email' ? 'I have a code' : 'Send another code'}</button>
      </div>
      <noscript><p>Enable JavaScript to request or enter your emailed access code.</p></noscript>
    </section>
  )
}
