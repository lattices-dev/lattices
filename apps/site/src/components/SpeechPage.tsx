import { SiteFooter, SiteHeader } from './SiteChrome'
import { SpeechMark } from './SpeechMark'
import { speechDownloadUrl as downloadUrl } from '../seo/routes'
const sourceUrl = 'https://github.com/lattices-dev/lattices/tree/main/products/voice'

const features = [
  {
    title: 'A unified speak API',
    description:
      'Any agent can say things out loud through one local interface — queue text, pick a voice, and playback keeps running even if the client disconnects.',
  },
  {
    title: 'Background by default',
    description:
      'A task finishes and its summary is queued and spoken while you keep working. Define it once and every agent you run gets a voice.',
  },
  {
    title: 'A readalong when you want it',
    description:
      'Speech shows a lightweight HUD over the workspace while it reads — follow along, or let it run quietly and check the queue later.',
  },
]

const steps = [
  {
    title: 'Enqueue the words',
    description:
      'Agents and scripts call the local RPC with the text to say — no synthesis code, no audio handling, no process babysitting on their side.',
  },
  {
    title: 'Speech owns the queue',
    description:
      'Speech.app holds the queue, picks the voice, and plays in the background. The job is safe even if the client that queued it exits.',
  },
  {
    title: 'Follow along — or don\u2019t',
    description:
      'An optional HUD reads along over the workspace while it plays. Pause, resume, seek, skip, or stop from the same API.',
  },
]

const voices = [
  {
    title: 'System voices',
    label: 'offline · zero setup',
    description:
      'macOS AVSpeech synthesis out of the box. No keys, no model downloads, works the moment Speech.app launches.',
  },
  {
    title: 'Kokoro on-device',
    label: 'local neural · no account',
    description:
      'The Kokoro-82M model runs fully on-device — a natural voice without a network call or an API key.',
  },
  {
    title: 'OpenAI TTS via Vox',
    label: 'cloud quality · your key',
    description:
      'Bring an OpenAI credential for hosted voices like gpt-4o-mini-tts. Keys live in the Keychain, never in prefs or logs.',
  },
]

const ambient = [
  { event: 'Download finished', detail: 'a long fetch completes in the background' },
  { event: 'Build done', detail: 'the release build finishes while you read mail' },
  { event: 'Agent summary', detail: 'a task closes out and its result is read back' },
]

export default function SpeechPage() {
  return (
    <div className="family-page speech-page">
      <SiteHeader product={{ name: 'speech', href: '/speech', mark: <SpeechMark /> }} />
      <main>
        <section className="family-hero" aria-labelledby="speech-title">
          <div className="family-hero-copy">
            <p className="family-kicker">Speech — a voice for agents</p>
            <h1 id="speech-title">Give your agents a voice.</h1>
            <p>
              Speech is a standalone player from Lattices: one local API for
              agents and scripts to queue spoken readouts, with an optional HUD
              readalong. Powered by Lattices, it can go ambient — a download
              finished, a build done — spoken in the background.
            </p>
            <div className="family-hero-actions">
              <a href={downloadUrl}>Download Speech</a>
              <a href={sourceUrl}>Read the source</a>
            </div>
            <p className="speech-platform-note">macOS 26+ · Apple silicon · signed + notarized</p>
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
          <span>ws://127.0.0.1:9397</span>
          <span>Capability-authed RPC</span>
          <span>Queue-owned playback</span>
          <span>HUD readalong</span>
        </div>

        <section className="speech-how" aria-labelledby="speech-how-title">
          <div className="speech-how-copy">
            <p className="family-kicker">How a readout happens</p>
            <h2 id="speech-how-title">Three calls deep. That&apos;s the whole surface.</h2>
            <p>
              Every spoken readout travels one short path: a client enqueues
              text, Speech plays it, and anyone listening hears the result.
              The RPC set stays tiny on purpose — enqueue, status, pause,
              resume, seek, stop, next, voices.
            </p>
          </div>
          <div className="speech-terminal" aria-label="Speech RPC example">
            <div className="speech-terminal-bar">ws://127.0.0.1:9397</div>
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
            <p className="family-kicker">Pick a voice</p>
            <h2 id="speech-voices-title">Three ways to sound.</h2>
            <p>
              Every provider shares the same queue and the same calls — a
              preferred voice per provider is remembered locally, and an
              explicit <code>voice</code> on enqueue always wins.
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
            <p className="family-kicker">The readalong</p>
            <h2 id="speech-hud-title">A HUD that follows the voice.</h2>
            <p>
              While Speech plays, a small overlay can float over the workspace
              and read along — enough to glance at what&apos;s being said without
              interrupting the task at hand. Turn it off and the queue still
              runs; Speech is a player first, a window second.
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
            <p className="family-kicker">One family, clear ownership</p>
            <h2 id="speech-boundary-title">Lattices enqueues. Speech speaks.</h2>
          </div>
          <div className="speech-boundary-grid">
            <article>
              <span className="speech-boundary-label">Lattices</span>
              <h3>A client like any other</h3>
              <p>
                The workspace daemon, your agents, and your scripts all call the
                same RPC. Nobody owns the queue but Speech — clients hand over
                text and get a job id back.
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
              <span className="speech-boundary-label speech-boundary-label-product">Speech</span>
              <h3>Owns the whole readout</h3>
              <p>
                Synthesis requests, queue state, audio playback, the HUD, and
                voice preferences all live in Speech.app — a signed, separate
                process that keeps playing when clients disconnect.
              </p>
              <a href={sourceUrl}>Read the source →</a>
            </article>
          </div>
        </section>

        <section className="speech-ambient" aria-labelledby="speech-ambient-title">
          <div className="speech-section-heading">
            <p className="family-kicker">Powered by Lattices</p>
            <h2 id="speech-ambient-title">Then it goes ambient.</h2>
            <p>
              Wired into the workspace, Speech stops being a command and becomes
              a sense — the desktop narrating its own events in the background.
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

        <section className="speech-features" aria-label="What Speech does">
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
            <h2 id="speech-source-title">A signed app you can rebuild.</h2>
            <p>
              Speech is Swift all the way down — the RPC server, the queue, the
              HUD, and the Vox/Kokoro providers all live in{' '}
              <code>products/voice</code>.
            </p>
            <ul className="speech-source-reqs">
              <li>macOS 26+ on Apple silicon</li>
              <li>Swift toolchain</li>
              <li>No permissions required to speak</li>
            </ul>
            <a href={sourceUrl} className="speech-source-link">Browse products/voice →</a>
          </div>
          <div className="speech-terminal" aria-label="Speech source commands">
            <div className="speech-terminal-bar">products/voice</div>
            <pre className="speech-terminal-body">
              <code>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">$</span> swift test --package-path products/voice</span>
                <span className="speech-terminal-output">Speech tests passed</span>
                <span className="speech-terminal-line"><span className="speech-terminal-prompt">$</span> tools/package.sh</span>
                <span className="speech-terminal-output">Speech.dmg signed + notarized</span>
              </code>
            </pre>
          </div>
        </section>

        <section className="family-close">
          <div>
            <p className="family-kicker">Independent, always listening</p>
            <h2>Speech owns its queue and keeps running when a client disconnects.</h2>
          </div>
          <nav aria-label="Lattices products">
            <a href="/">Lattices</a>
            <a href="/action">Action</a>
            <a href="/blink">Blink</a>
            <a href="/family">Family</a>
          </nav>
        </section>
      </main>
      <SiteFooter current="/speech" />
    </div>
  )
}
