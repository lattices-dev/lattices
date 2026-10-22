import { useState } from 'react'
import { SiteFooter, SiteHeader } from './SiteChrome'
import { linuxInstallCommand, linuxInstallerUrl } from '../seo/routes'
import '../styles/linux.css'

// Every claim on this page follows docs/install-linux.md, apps/linux/README.md
// and packages/host-linux/README.md on main. Keep them in step.
const setupGuide = '/lattices/docs/install-linux'
const appReadme = 'https://github.com/lattices-dev/lattices/blob/main/apps/linux/README.md'
const hostReadme = 'https://github.com/lattices-dev/lattices/blob/main/packages/host-linux/README.md'

const installSteps = [
  ['Dependencies', 'Installs missing Arch packages and Bun. Nothing runs as root except pacman.'],
  ['Runtime', 'Copies the Linux runtime into ~/.local/share/lattices. The source checkout can go afterwards.'],
  ['Commands', 'Adds lats, lattices and lattices-host to ~/.local/bin and a launcher to the Apps menu.'],
  ['Services', 'Enables lattices-host and lattices-tray as systemd user services. Both start at login.'],
  ['Check', 'Runs lats doctor and opens the app.'],
]

const installFlags = [
  ['--gestures', 'Forward-button mouse gestures on Omarchy'],
  ['--wheel-gestures', 'Wheel-click gestures for a mouse without a Forward button'],
  ['--no-start', 'Install the files over SSH, activate later with lats app install'],
  ['--dry-run', 'Print the plan. Downloads nothing, writes nothing'],
  ['--no-deps', 'Another distribution: bring the dependencies, run from a checkout'],
]

const doctorChecks = [
  ['Host connection', 'Reachable · version 0.15.1'],
  ['Window inventory', 'windows.read'],
  ['Window placement', 'windows.place'],
  ['Spaces', 'spaces.read'],
  ['Terminal sessions', 'sessions.tmux'],
  ['Desktop events', 'connected'],
]

const togetherSteps = [
  {
    where: 'archie',
    os: 'Linux',
    command: 'lats gateway start --tailnet',
    note: 'The host listens only on private sockets. The gateway binds this machine’s Tailscale address, port 9399.',
  },
  {
    where: 'mini',
    os: 'macOS',
    command: 'lats --host archie pair',
    note: 'The Mac makes a key and asks for read, screen and act. Add --drive for input, or --read-only for a viewer.',
  },
  {
    where: 'archie',
    os: 'Linux',
    command: 'lats gateway approve <client>',
    note: 'Check the fingerprint with lats gateway clients first. Approval only works from the host itself.',
  },
  {
    where: 'mini',
    os: 'macOS',
    command: 'lats visit pair archie archie:9399 right',
    note: 'Then arrange the two machines in Workspace → Machines, the way you arrange displays.',
  },
]

const features = [
  {
    key: '⌃2',
    name: 'Flight Deck',
    text: 'Every space on a display as one continuous map with live window geometry. Zoom, inspect a space without switching to it, pick a window and place it. A preview draws the planned frame in amber before anything moves.',
  },
  {
    key: '⌃3',
    name: 'Layers',
    text: 'Save windows into named layers and switch them with In place, Auto, Columns or Master stack. Linux edits the same ~/.lattices/workspace.json the Mac app uses.',
  },
  {
    key: '⌃6',
    name: 'Mission Control',
    text: 'One inventory of live windows across spaces plus the windows a layer parked. Filter by title, app, window ID or layer. Enter focuses the row.',
  },
  {
    key: '⌃7',
    name: 'Operator Console',
    text: 'Type lats commands and read the receipts in a transcript. --dry-run previews focus, placement and space changes. The console never runs shell text.',
  },
  {
    key: 'PiP',
    name: 'Virtual space',
    text: 'A headless 1280 × 800 Sway desktop for agents, with a browser and a terminal preset. Watch it in a floating viewer. The physical pointer and focus stay yours.',
  },
  {
    key: 'API',
    name: 'Virtual displays',
    text: 'displays.create adds a headless output; displays.remove takes only the ones the host made. Hand-made outputs stay yours unless you adopt them.',
  },
  {
    key: 'tray',
    name: 'Omarchy tray',
    text: 'A StatusNotifierItem in Omarchy’s own tray: Bring Cursor Home, host and companion pairing status, Start and Stop Host. Nothing is written under /usr/share/omarchy.',
  },
  {
    key: 'fwd',
    name: 'Mouse gestures',
    text: 'Hold the Forward button and draw. Left and right move between existing spaces, down shows the overlay, down then left sends Enter. Super+Ctrl+G opens a tester.',
  },
  {
    key: 'F1',
    name: 'Theme and hints',
    text: 'The app follows Omarchy’s current colors and light or dark mode within a second. F1 opens a hints pack for Omarchy, layers, sessions and shortcuts; lats hints prints the same pack.',
  },
]

const requirements = [
  {
    title: 'Required',
    items: [
      ['Hyprland', 'with a systemd user session'],
      ['Omarchy on Arch Linux', 'for the automatic dependency setup'],
      ['x86-64 or ARM64', ''],
      ['Bun and Quickshell', 'installed when missing'],
    ],
  },
  {
    title: 'Checked by the installer',
    items: [
      ['tmux', 'sessions'],
      ['grim and wtype', 'capture and keys'],
      ['tesseract', 'screen text'],
      ['ffmpeg and Python', 'recording and gestures'],
    ],
  },
  {
    title: 'Optional',
    items: [
      ['Tailscale', 'pairing, visits and remote agents'],
      ['sway, foot, Chromium', 'Virtual space'],
      ['Hyprland 0.56 and Omarchy’s Lua config', 'mouse gestures'],
      ['Another distribution', 'bring the tools, then --no-deps'],
    ],
  },
]

export default function LinuxPage() {
  const [copy, setCopy] = useState('Copy')
  async function copyInstall() {
    try {
      await navigator.clipboard.writeText(linuxInstallCommand)
      setCopy('Copied')
      window.setTimeout(() => setCopy('Copy'), 2000)
    } catch {
      setCopy('Select to copy')
    }
  }

  return (
    <div className="linux-page">
      <SiteHeader docsProductId="lattices" />
      <main data-pagefind-body>
        <section className="lx-hero" aria-labelledby="lx-title">
          <div className="lx-hero-copy">
            <p className="lx-kicker">
              <span className="lx-omarchy-mark" aria-hidden="true">
                <img src="/brand/omarchy/logo.svg" alt="" width="16" height="16" />
              </span>
              Lattices for Linux · Hyprland and Omarchy
            </p>
            <h1 id="lx-title">The same workspace, on Hyprland.</h1>
            <p className="lx-lede">
              Lattices on Linux is a desktop app, the <code>lats</code> CLI, a local
              host and a tray menu. One command installs it on Omarchy. Agents get the
              API they already use on a Mac, and a Mac and a Linux machine can share
              one desk.
            </p>
            <div className="lx-hero-actions">
              <a href="#install" className="lx-button is-primary">Install on Linux</a>
              <a href={setupGuide} className="lx-button">Setup guide</a>
            </div>
            <p className="lx-platform">Omarchy on Arch · Hyprland · systemd user session · x86-64 and ARM64</p>
          </div>
          <FlightDeck />
        </section>

        <div className="lx-rail" aria-label="How the Linux build is put together">
          <span><code>lattices.sock</code> private IPC</span>
          <span>Quickshell app</span>
          <span>Bun host</span>
          <span><code>systemctl --user</code> services</span>
          <span>Tailscale optional</span>
        </div>

        <section className="lx-install" id="install" aria-labelledby="lx-install-title">
          <div className="lx-section-head">
            <p className="lx-kicker">Install</p>
            <h2 id="lx-install-title">One command, from a terminal inside Hyprland.</h2>
            <p>
              Run it as your own user. The installer uses sudo only to add missing
              Arch packages, reports clearly when it cannot reach the desktop, and
              leaves older runtimes in place for recovery.
            </p>
          </div>

          <div className="lx-install-grid">
            <div className="lx-install-main">
              <div className="lx-terminal lx-install-command">
                <div className="lx-terminal-bar">
                  <span>omarchy · foot</span>
                  <span className="lx-live"><i aria-hidden="true" />LIVE</span>
                </div>
                <div className="lx-install-line">
                  <code><span className="lx-prompt">$</span> {linuxInstallCommand}</code>
                  <button type="button" onClick={copyInstall} aria-label="Copy the Linux install command">{copy}</button>
                </div>
                <span className="sr-only" role="status">{copy === 'Copied' ? 'Linux install command copied' : ''}</span>
              </div>

              <ol className="lx-receipt" aria-label="What the installer does">
                {installSteps.map(([title, text], index) => (
                  <li key={title}>
                    <span className="lx-receipt-index">{String(index + 1).padStart(2, '0')}</span>
                    <div>
                      <strong>{title}</strong>
                      <p>{text}</p>
                    </div>
                  </li>
                ))}
              </ol>
            </div>

            <aside className="lx-install-side">
              <div className="lx-flags">
                <h3>Options</h3>
                <dl>
                  {installFlags.map(([flag, text]) => (
                    <div key={flag}>
                      <dt><code>{flag}</code></dt>
                      <dd>{text}</dd>
                    </div>
                  ))}
                </dl>
                <p>
                  Append options after <code>bash -s --</code> when piping, or pass them
                  to <code>bash install.sh</code> from a checkout. Rerun the same command
                  to update.
                </p>
              </div>

              <div className="lx-terminal lx-doctor" aria-label="Example lats doctor output">
                <div className="lx-terminal-bar"><span>$ lats doctor</span></div>
                <ul>
                  {doctorChecks.map(([name, detail]) => (
                    <li key={name}>
                      <span className="lx-pass" aria-hidden="true">✓</span>
                      <span>{name}</span>
                      <code>{detail}</code>
                    </li>
                  ))}
                </ul>
                <p>Read-only checks. Doctor never sends input or moves a window.</p>
              </div>
            </aside>
          </div>
        </section>

        <section className="lx-together" id="together" aria-labelledby="lx-together-title">
          <div className="lx-section-head">
            <p className="lx-kicker">Mac and Linux</p>
            <h2 id="lx-together-title">Two machines. One desk.</h2>
            <p>
              The Linux host speaks the Mac daemon’s protocol: the same envelope,
              method names and window shapes. So a Mac can list, place, see and drive
              windows on a Linux machine, and lend it a cursor.
            </p>
          </div>

          <TwoMachines />

          <div className="lx-together-grid">
            <article>
              <h3>Visit with your cursor</h3>
              <p>
                Push the Mac’s pointer past the edge that faces the Linux machine. A
                coral visitor appears on its screens, labelled with your Mac’s name, and
                your keys type there. Your own cursor never leaves, so nothing can
                strand it. <kbd>⌃⌥⌘ Home</kbd> brings it back; Bring Cursor Home in the
                tray does the same from the host.
              </p>
            </article>
            <article>
              <h3>Drive it from the CLI</h3>
              <p>
                <code>lats machines</code> lists every machine with its build, displays
                and pairing. <code>lats @archie</code> runs a command there,
                and <code>lats --host archie call windows.place</code> moves a window on
                the other desk. Clicks and keys stage first and act only
                with <code>treatment: "execute"</code>.
              </p>
            </article>
            <article>
              <h3>Give agents the same API</h3>
              <p>
                <code>host.describe</code> reports the platform, displays and
                capabilities, so clients branch on what a host has, never on its OS.
                Action’s remote engine, the <code>hosts</code> MCP toolset and the iOS
                companion all reach a Linux machine through the gateway.
              </p>
            </article>
          </div>

          <ol className="lx-pairing" aria-label="Pairing a Mac with a Linux machine">
            {togetherSteps.map((step, index) => (
              <li key={step.command}>
                <span className="lx-pairing-index">{String(index + 1).padStart(2, '0')}</span>
                <span className={`lx-machine-tag is-${step.os === 'Linux' ? 'linux' : 'mac'}`}>
                  {step.where} <small>{step.os}</small>
                </span>
                <code>{step.command}</code>
                <p>{step.note}</p>
              </li>
            ))}
          </ol>
          <p className="lx-footnote">
            Visits travel from a Mac to a Linux machine, or between Macs. A Linux
            machine receives. Remote access needs Tailscale; everything local works
            without it.
          </p>
        </section>

        <section className="lx-features" id="features" aria-labelledby="lx-features-title">
          <div className="lx-section-head">
            <p className="lx-kicker">In the app</p>
            <h2 id="lx-features-title">Built for a tiling desktop, not ported to one.</h2>
            <p>
              The Linux app is Quickshell and Qt Quick on top of the host. It keeps the
              Mac app’s navigation and adds the views a Hyprland desktop asks for.
            </p>
          </div>
          <div className="lx-feature-grid">
            {features.map((feature) => (
              <article key={feature.name}>
                <kbd>{feature.key}</kbd>
                <h3>{feature.name}</h3>
                <p>{feature.text}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="lx-requirements" id="requirements" aria-labelledby="lx-req-title">
          <div className="lx-section-head">
            <p className="lx-kicker">Requirements</p>
            <h2 id="lx-req-title">What the machine needs.</h2>
          </div>
          <div className="lx-req-grid">
            {requirements.map((group) => (
              <div key={group.title} className="lx-req-group">
                <h3>{group.title}</h3>
                <ul>
                  {group.items.map(([name, detail]) => (
                    <li key={name}>
                      <span>{name}</span>
                      {detail ? <small>{detail}</small> : null}
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
          <div className="lx-req-files">
            <p>
              Everything lands under your home directory: launchers
              in <code>~/.local/bin</code>, the runtime
              in <code>~/.local/share/lattices</code>, services
              in <code>~/.config/systemd/user</code>, and backups
              in <code>~/.local/state/lattices</code>. Saved layers, pairings and captures
              stay in <code>~/.lattices</code>, apart from installed code.
            </p>
            <div className="lx-req-links">
              <a href={setupGuide}>Full setup and recovery guide →</a>
              <a href={appReadme} target="_blank" rel="noopener noreferrer">Linux app README ↗</a>
              <a href={hostReadme} target="_blank" rel="noopener noreferrer">lattices-host README ↗</a>
            </div>
          </div>
        </section>

        <section className="lx-close">
          <div>
            <p className="lx-kicker">Local first</p>
            <h2>The host listens on a private socket. Remote access is a separate, opt-in gateway.</h2>
          </div>
          <div className="lx-close-actions">
            <a href={linuxInstallerUrl} className="lx-button" target="_blank" rel="noopener noreferrer">Read install.sh ↗</a>
            <a href="/lattices/docs/concepts" className="lx-button">How the pieces fit</a>
          </div>
        </section>
      </main>
      <SiteFooter current="/linux" />
    </div>
  )
}

/* The hero instrument: a Flight Deck map of three spaces on one display, with
   a placement preview and a visiting cursor from a paired Mac. Decorative. */
function FlightDeck() {
  return (
    <figure className="lx-deck" aria-hidden="true">
      <div className="lx-deck-bar">
        <span>Flight Deck · HDMI-A-1 · 3440 × 1440</span>
        <span className="lx-live"><i />LIVE</span>
      </div>
      <svg className="lx-deck-map" viewBox="0 0 640 300" focusable="false">
        {/* space 1 */}
        <g className="lx-space">
          <rect x="12" y="34" width="196" height="118" rx="4" />
          <text x="18" y="27" className="lx-space-label">1 · code</text>
          <rect className="lx-win" x="20" y="42" width="110" height="102" rx="2" />
          <rect className="lx-win" x="136" y="42" width="64" height="48" rx="2" />
          <rect className="lx-win" x="136" y="96" width="64" height="48" rx="2" />
          <text x="26" y="56" className="lx-win-label">zed · tideline</text>
          <text x="142" y="56" className="lx-win-label">foot</text>
          <text x="142" y="110" className="lx-win-label">foot</text>
        </g>
        {/* space 2, inspected */}
        <g className="lx-space is-inspected">
          <rect x="222" y="34" width="196" height="118" rx="4" />
          <text x="228" y="27" className="lx-space-label">2 · browse</text>
          <circle cx="302" cy="24" r="2.5" className="lx-space-dot" />
          <rect className="lx-win" x="230" y="42" width="88" height="102" rx="2" />
          <rect className="lx-win is-selected" x="324" y="42" width="86" height="102" rx="2" />
          <text x="236" y="56" className="lx-win-label">firefox</text>
          <text x="330" y="56" className="lx-win-label is-selected">foot · claude</text>
          <rect className="lx-preview" x="230" y="42" width="180" height="102" rx="2" />
          <text x="236" y="138" className="lx-preview-label">preview · place right</text>
          {/* visiting cursor from the Mac */}
          <g className="lx-visitor" transform="translate(360 96)">
            <path d="M0 0l0 13 3.4-3.2 2.4 5.4 2.6-1.1-2.4-5.4 4.6 0z" />
            <rect x="12" y="4" width="30" height="12" rx="6" />
            <text x="27" y="12.8" textAnchor="middle">mini</text>
          </g>
        </g>
        {/* space 3 */}
        <g className="lx-space">
          <rect x="432" y="34" width="196" height="118" rx="4" />
          <text x="438" y="27" className="lx-space-label">3 · agents</text>
          <rect className="lx-win" x="440" y="42" width="180" height="48" rx="2" />
          <rect className="lx-win" x="440" y="96" width="86" height="48" rx="2" />
          <rect className="lx-win" x="532" y="96" width="88" height="48" rx="2" />
          <text x="446" y="56" className="lx-win-label">codex · fab</text>
          <text x="446" y="110" className="lx-win-label">foot</text>
          <text x="538" y="110" className="lx-win-label">virtual · sway</text>
        </g>
        {/* target panel */}
        <g className="lx-target">
          <rect x="12" y="172" width="616" height="116" rx="4" />
          <text x="26" y="196" className="lx-target-kicker">TARGET</text>
          <text x="26" y="218" className="lx-target-title">foot · claude</text>
          <text x="26" y="236" className="lx-target-meta">wid 0x5a3f1c · space 2 · 1712 × 1392</text>
          <text x="26" y="270" className="lx-target-cmd">$ lats window place 0x5a3f1c right --dry-run</text>
          <g className="lx-placements" transform="translate(470 192)">
            <rect x="0" y="0" width="30" height="20" rx="2" /><rect className="is-fill" x="0" y="0" width="15" height="20" rx="2" />
            <rect x="38" y="0" width="30" height="20" rx="2" /><rect className="is-fill is-active" x="53" y="0" width="15" height="20" rx="2" />
            <rect x="76" y="0" width="30" height="20" rx="2" /><rect className="is-fill" x="76" y="0" width="30" height="10" rx="2" />
            <rect x="114" y="0" width="30" height="20" rx="2" /><rect className="is-fill" x="114" y="10" width="30" height="10" rx="2" />
            <rect x="0" y="28" width="30" height="20" rx="2" /><rect className="is-fill" x="0" y="28" width="30" height="20" rx="2" />
            <rect x="38" y="28" width="30" height="20" rx="2" /><rect className="is-fill" x="45" y="33" width="16" height="10" rx="1.5" />
            <rect x="76" y="28" width="30" height="20" rx="2" /><rect className="is-fill" x="76" y="28" width="15" height="10" rx="2" />
            <rect x="114" y="28" width="30" height="20" rx="2" /><rect className="is-fill" x="129" y="38" width="15" height="10" rx="2" />
            <text x="0" y="70" className="lx-target-meta">placement · right</text>
          </g>
        </g>
      </svg>
      <div className="lx-deck-keys">
        <span><kbd>0</kbd> fit all</span>
        <span><kbd>1</kbd> space</span>
        <span><kbd>[</kbd><kbd>]</kbd> inspect</span>
        <span><kbd>⌃K</kbd> search</span>
        <span><kbd>↵</kbd> focus</span>
      </div>
    </figure>
  )
}

/* Two desks side by side: the Mac on the left, the Linux machine on the
   right, touching along the edge the cursor crosses. Decorative. */
function TwoMachines() {
  return (
    <figure className="lx-machines" aria-hidden="true">
      <svg viewBox="0 0 760 250" focusable="false">
        {/* Mac */}
        <g className="lx-mac">
          <text x="40" y="36" className="lx-m-name">mini <tspan className="lx-m-os">macOS</tspan></text>
          <rect x="40" y="48" width="250" height="156" rx="5" />
          <rect className="lx-m-win" x="52" y="60" width="110" height="132" rx="2" />
          <rect className="lx-m-win" x="170" y="60" width="108" height="62" rx="2" />
          <rect className="lx-m-win" x="170" y="130" width="108" height="62" rx="2" />
          <text x="40" y="226" className="lx-m-meta">Lattices.app · sends visits · lats @archie</text>
        </g>
        {/* Linux */}
        <g className="lx-linux">
          <text x="312" y="36" className="lx-m-name">archie <tspan className="lx-m-os">Hyprland</tspan></text>
          <rect x="312" y="64" width="408" height="124" rx="5" />
          <rect className="lx-m-win" x="324" y="76" width="170" height="100" rx="2" />
          <rect className="lx-m-win" x="502" y="76" width="100" height="100" rx="2" />
          <rect className="lx-m-win is-virtual" x="610" y="76" width="98" height="46" rx="2" />
          <rect className="lx-m-win" x="610" y="130" width="98" height="46" rx="2" />
          <text x="616" y="90" className="lx-m-label">LATS-1 · virtual</text>
          <text x="312" y="226" className="lx-m-meta">lattices-host · receives visits · gateway :9399 on the tailnet</text>
        </g>
        {/* the shared edge and the crossing */}
        <line className="lx-edge" x1="301" y1="64" x2="301" y2="188" />
        <path className="lx-cross" d="M232 118 C 270 118, 290 118, 330 118" />
        <g className="lx-visitor" transform="translate(338 110)">
          <path d="M0 0l0 13 3.4-3.2 2.4 5.4 2.6-1.1-2.4-5.4 4.6 0z" />
          <rect x="12" y="4" width="30" height="12" rx="6" />
          <text x="27" y="12.8" textAnchor="middle">mini</text>
        </g>
        <circle className="lx-home-cursor" cx="232" cy="118" r="3" />
        <text x="232" y="106" textAnchor="middle" className="lx-m-label">parked</text>
      </svg>
      <figcaption>
        The Mac’s own cursor parks at the edge while the visitor moves on the Linux screens.
        Frames are signed and encrypted; six quiet seconds end the visit.
      </figcaption>
    </figure>
  )
}
