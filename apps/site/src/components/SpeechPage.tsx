import { SiteFooter, SiteHeader } from './SiteChrome'
import { SpeechMark } from './SpeechMark'
import { speechDownloadUrl as downloadUrl } from '../seo/routes'
const sourceUrl = 'https://github.com/lattices-dev/lattices/tree/main/products/voice'

const features = [
  {
    title: 'One call to speak',
    description:
      'Any agent or script sends text to one local socket. Voice queues it and reads it aloud, and the readout finishes even if the sender quits.',
  },
  {
    title: 'Hear when work finishes',
    description:
      'When a task ends, its summary is read out while you keep working. Set it up once and every agent you run can use it.',
  },
  {
    title: 'See what is playing',
    description:
      'A small panel shows the text being read, its progress and how many readouts are queued. It hides when the queue is empty.',
  },
]

const steps = [
  {
    title: 'Send the text',
    description:
      'An agent or script sends the words to Voice over a local socket. It needs no speech code and no audio library.',
  },
  {
    title: 'Voice queues it',
    description:
      'Voice holds the queue, picks the voice and plays each job in order. A job keeps playing if the sender exits.',
  },
  {
    title: 'Control playback',
    description:
      'Pause, resume, seek, skip or stop with the same calls. A small panel shows what is playing.',
  },
]

const voices = [
  {
    title: 'System voices',
    label: 'offline · zero setup',
    description:
      'The voices built into macOS. No keys and no downloads; they work as soon as Voice opens.',
  },
  {
    title: 'Kokoro on-device',
    label: 'local neural · no account',
    description:
      'Kokoro downloads its model and voice assets on first use, then speaks on your Mac without a network connection or an API key.',
  },
  {
    title: 'OpenAI TTS via Vox',
    label: 'cloud quality · your key',
    description:
      'Add an OpenAI key to use hosted voices such as gpt-4o-mini-tts. The key stays in the Keychain, never in settings files or logs.',
  },
]

const ambient = [
  { event: 'Download finished', detail: 'a long fetch completes in the background' },
  { event: 'Build done', detail: 'a release build finishes while you read email' },
  { event: 'Agent summary', detail: 'an agent finishes a task and Voice reads its result' },
]

export default function SpeechPage() {
  return (
    <div className="family-page speech-page">
      <SiteHeader product={{ name: 'voice', href: '/voice', mark: <SpeechMark /> }} docsProductId="speech" />
      <main>
        <section className="family-hero" aria-labelledby="speech-title">
          <div className="family-hero-copy">
            <p className="family-kicker">Voice, for agents</p>
            <h1 id="speech-title">Give your agents a voice.</h1>
            <p>
              Voice is a standalone app in the Lattices family. Agents and
              scripts send it text over one local API, and it reads the text
              aloud in order, showing what it reads in a small panel.
              With Lattices running, it also tells you when things happen: a
              download finishes, a build is done.
            </p>
            <div className="family-hero-actions">
              <a href={downloadUrl}>Download Voice</a>
              <a href="/voice/docs">Read the docs</a>
            </div>
            <p className="speech-platform-note">macOS 26+ · Apple silicon · signed + notarized</p>
            <p className="speech-platform-note">Speech 0.3.0 downloads as Speech.app and appears as Voice in the menu bar. Use it with Lattices app and CLI 0.15.1.</p>
          </div>
          <div className="family-speech-visual speech-queue-hero" aria-hidden="true">
            <div className="is-playing">
              <span>▶</span>
              <strong>Agent summary — release build</strong>
              <time>02:14</time>
            </div>
            <div>
              <span>02</span>
              <strong>Download finished</strong>
              <time>00:08</time>
            </div>
            <div>
              <span>03</span>
              <strong>Release notes draft</strong>
              <time>01:42</time>
            </div>
          </div>
        </section>

        <div className="speech-tech-rail" aria-label="Core surfaces">
          <span>speech.sock</span>
          <span>Authenticated local RPC</span>
          <span>Queue-owned playback</span>
          <span>HUD readalong</span>
        </div>

        <section className="speech-how" aria-labelledby="speech-how-title">
          <div className="speech-how-copy">
            <p className="family-kicker">How it works</p>
            <h2 id="speech-how-title">Speaking takes one call.</h2>
            <p>
              An agent sends text and Voice reads it aloud. Seven more calls
              cover the rest: status, pause, resume, seek, stop, next and
              voices.
            </p>
          </div>
          <div className="speech-terminal" aria-label="Voice RPC example">
            <div className="speech-terminal-bar">speech.sock</div>
            <pre className="speech-terminal-body">
              <code>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">→</span> speech.enqueue {'{ "text": "Release build finished. 34 tests passed.", "voice": "af_heart" }'}</span>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">←</span> {'{ "id": "job_9f3", "state": "queued" }'}</span>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">→</span> speech.status</span>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">←</span> playing · 01:58 remaining</span>
              </code>
            </pre>
          </div>
        </section>

        <section className="speech-steps" aria-label="The path of a readout">
          {steps.map((step, index) => (
            <article key={step.title}>
              <span>{String(index + 1).padStart(2, '0')}</span>
              <h3>{step.title}</h3>
              <p>{step.description}</p>
            </article>
          ))}
        </section>

        <section className="speech-voices" aria-labelledby="speech-voices-title">
          <div className="speech-section-heading">
            <p className="family-kicker">Voices</p>
            <h2 id="speech-voices-title">Three kinds of voice.</h2>
            <p>
              Every provider uses the same queue and the same calls. Voice
              remembers a preferred voice for each provider, and a{' '}
              <code>voice</code> named in the request always wins.
            </p>
          </div>
          <div className="speech-voice-grid">
            {voices.map((voice) => (
              <article key={voice.title}>
                <span className="speech-voice-label">{voice.label}</span>
                <h3>{voice.title}</h3>
                <p>{voice.description}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="speech-hud" aria-labelledby="speech-hud-title">
          <div className="speech-hud-copy">
            <p className="family-kicker">Playback panel</p>
            <h2 id="speech-hud-title">See what it&apos;s reading.</h2>
            <p>
              While Voice plays, a small panel shows the text being read, its
              progress and what&apos;s queued next, without taking focus from
              what you&apos;re doing. It hides when the queue is empty, and the
              menu bar brings it back.
            </p>
          </div>
          <div className="speech-hud-visual" aria-hidden="true">
            <div className="speech-hud-pill">
              <span className="speech-hud-dot" />
              <div className="speech-hud-text">
                <strong>Reading · Agent summary</strong>
                <span>the release build finished — thirty-four tests passed…</span>
              </div>
              <span className="speech-hud-time">01:58</span>
            </div>
          </div>
        </section>

        <section className="speech-boundary" aria-labelledby="speech-boundary-title">
          <div className="speech-section-heading">
            <p className="family-kicker">Who does what</p>
            <h2 id="speech-boundary-title">Lattices sends. Voice speaks.</h2>
          </div>
          <div className="speech-boundary-grid">
            <article>
              <span className="speech-boundary-label">Lattices</span>
              <h3>One client among many</h3>
              <p>
                The Lattices app, your agents and your scripts all use the same
                calls. They send text and get a job id back; only Voice manages
                the queue.
              </p>
              <a href="/">Explore Lattices →</a>
            </article>
            <div className="speech-boundary-bridge" aria-hidden="true">
              <span>enqueue</span>
              <i />
              <span>queue</span>
              <i />
              <span>speak</span>
            </div>
            <article>
              <span className="speech-boundary-label speech-boundary-label-product">Voice</span>
              <h3>Handles everything after that</h3>
              <p>
                Voice.app does the synthesis, the queue, the audio, the panel
                and the voice settings. It is a separate signed app, so playback
                continues when a client disconnects.
              </p>
              <a href={sourceUrl}>Read the source →</a>
            </article>
          </div>
        </section>

        <section className="speech-ambient" aria-labelledby="speech-ambient-title">
          <div className="speech-section-heading">
            <p className="family-kicker">With Lattices</p>
            <h2 id="speech-ambient-title">Hear what your Mac is doing.</h2>
            <p>
              With Lattices running, Voice can announce events as they happen,
              so you don&apos;t have to keep checking.
            </p>
          </div>
          <div className="speech-ambient-grid">
            {ambient.map((item) => (
              <article key={item.event}>
                <strong>{item.event}</strong>
                <p>{item.detail}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="speech-features" aria-label="What Voice does">
          {features.map((feature) => (
            <article key={feature.title}>
              <h2>{feature.title}</h2>
              <p>{feature.description}</p>
            </article>
          ))}
        </section>

        <section className="speech-source" aria-labelledby="speech-source-title">
          <div className="speech-source-copy">
            <p className="family-kicker">From source</p>
            <h2 id="speech-source-title">Build the next version.</h2>
            <p>
              Voice is written in Swift. The API server, the queue, the panel
              and speech providers are all in{' '}
              <code>products/voice</code>.
            </p>
            <p>
              Upcoming source builds replace Kokoro with Phonon on the Neural
              Engine. The first use downloads a 137 MB model; speech then runs
              locally. Phonon uses a fixed speaking rate. This change is not
              included in the Speech 0.3.0 download above.
            </p>
            <ul className="speech-source-reqs">
              <li>macOS 26+ on Apple silicon</li>
              <li>Swift toolchain</li>
              <li>No macOS permissions needed</li>
            </ul>
            <a href={sourceUrl} className="speech-source-link">Browse products/voice →</a>
          </div>
          <div className="speech-terminal" aria-label="Voice source commands">
            <div className="speech-terminal-bar">products/voice</div>
            <pre className="speech-terminal-body">
              <code>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">$</span> HUDSONKIT_WITH_VOICE=0 swift test --package-path products/voice</span>
                <span className="speech-terminal-output">Voice tests passed</span>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">$</span> products/voice/tools/package.sh</span>
                <span className="speech-terminal-output">Local Voice.app artifact</span>
              </code>
            </pre>
          </div>
        </section>

        <section className="family-close">
          <div>
            <p className="family-kicker">Runs on its own</p>
            <h2>Voice manages its own queue and keeps playing when a client disconnects.</h2>
          </div>
          <nav aria-label="Lattices products">
            <a href="/">Lattices</a>
            <a href="/action">Action</a>
            <a href="/canvas">Canvas</a>
            <a href="/family">Family</a>
          </nav>
        </section>
      </main>
      <SiteFooter current="/voice" />
    </div>
  )
}
