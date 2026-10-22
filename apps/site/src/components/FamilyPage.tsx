import type { ReactNode } from 'react'
import { SiteFooter, SiteHeader } from './SiteChrome'

export default function FamilyPage() {
  return (
    <div className="family-page">
      <SiteHeader />
      <main>
        <section className="family-hero" aria-labelledby="family-title">
          <div className="family-hero-copy">
            <p className="family-kicker">A window manager that knows about projects</p>
            <h1 id="family-title">Shape the desktop around the work.</h1>
            <p>
              Arrange windows, launch the right tools, and return to a complete working
              state instead of rebuilding it every morning.
            </p>
            <div className="family-hero-actions">
              <a href="/docs/quickstart">Start with Lattices</a>
              <a href="/docs/overview">Read the overview</a>
            </div>
          </div>
          <WorkspaceVisual />
        </section>

        <div className="family-capability-rail" aria-label="Capability sequence">
          <span>Arrange</span>
          <span>Collaborate</span>
          <span>Act</span>
          <span>Remember</span>
          <span>Listen</span>
        </div>

        <CapabilitySection
          label="Agents"
          kicker="Workspace access"
          title="Your agent works in the same workspace."
          description="It can inspect what is open, find the right window, and reshape the desktop with you, without inventing a second environment."
          product="Built into Lattices"
          href="/docs/api"
          visual={<AgentVisual />}
        />

        <CapabilitySection
          label="Computer use"
          kicker="When the work leaves the terminal"
          title="Let your computers use your workspace."
          description="Observe the screen, stage a computer-use step, review the target, then execute and verify it on device."
          product="Meet Action"
          href="/action"
          visual={<ActionVisual />}
        />

        <CapabilitySection
          label="Notes"
          kicker="Keep context where it belongs"
          title="Have your assistant create and manage notes in your workspace."
          description="Pin working memory beside the window it describes, so the thought survives after the tab, task, or conversation moves on."
          product="Meet Canvas"
          href="/canvas"
          visual={<NotesVisual />}
        />

        <CapabilitySection
          label="Voice"
          kicker="A voice for agents"
          title="Smart voice readouts with HUD readalong if you want it."
          description="One local API for agents to say things out loud. A task finishes, and its summary is queued and spoken in the background, whichever agent ran it. With Lattices it can also read out events, like a finished download."
          product="Meet Voice"
          href="/voice"
          visual={<SpeechVisual />}
        />

        <section className="family-close">
          <div>
            <p className="family-kicker">The Lattices family</p>
            <h2>Choose a product.</h2>
          </div>
          <nav aria-label="Lattices products">
            <a href="/">Lattices</a>
            <a href="/action">Action</a>
            <a href="/canvas">Canvas</a>
            <a href="/voice">Voice</a>
          </nav>
        </section>
      </main>

      <SiteFooter current="/family" />
    </div>
  )
}

function CapabilitySection({
  label,
  kicker,
  title,
  description,
  product,
  href,
  visual,
}: {
  label: string
  kicker: string
  title: string
  description: string
  product: string
  href: string
  visual: ReactNode
}) {
  return (
    <section className="family-capability">
      <p className="family-capability-index">
        {label}
      </p>
      <div className="family-capability-copy">
        <p className="family-kicker">{kicker}</p>
        <h2>{title}</h2>
        <p>{description}</p>
        <a className="family-product-link" href={href}>
          {product} <span aria-hidden="true">→</span>
        </a>
      </div>
      {visual}
    </section>
  )
}

function WorkspaceVisual() {
  return (
    <div className="family-workspace-visual" aria-hidden="true">
      <div className="family-command">Place editor left · terminal right →</div>
    </div>
  )
}

function AgentVisual() {
  return (
    <div className="family-agent-visual" aria-hidden="true">
      <div>
        <span>You</span>
        <strong>Open the work.</strong>
        <small>Sessions, windows, layers, and focus stay visible.</small>
      </div>
      <div>
        <span>Agent</span>
        <strong>Continue the work.</strong>
        <small>The same live state is available through the local API.</small>
      </div>
    </div>
  )
}

function ActionVisual() {
  return (
    <div className="family-action-visual" aria-hidden="true">
      <div className="family-action-screen">
        <span />
      </div>
      <div className="family-action-steps">
        <span>Observe</span>
        <span>Review target</span>
        <span>Execute</span>
      </div>
    </div>
  )
}

function NotesVisual() {
  return (
    <div className="family-notes-visual" aria-hidden="true">
      <div>
        Check the release path before merging.
        <small>Pinned to terminal</small>
      </div>
      <div>
        The workspace remembers where this belongs.
        <small>Spatial note</small>
      </div>
    </div>
  )
}

function SpeechVisual() {
  return (
    <div className="family-speech-visual" aria-hidden="true">
      <div className="is-playing">
        <span>▶</span>
        <strong>Why the family expanded</strong>
        <time>02:14</time>
      </div>
      <div>
        <span>02</span>
        <strong>Release notes draft</strong>
        <time>01:42</time>
      </div>
      <div>
        <span>03</span>
        <strong>Agent summary</strong>
        <time>00:58</time>
      </div>
    </div>
  )
}
