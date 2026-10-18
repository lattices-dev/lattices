import { useState } from "react";
import guide from "../data/action-start.json";

export function ActionQuickStart() {
  const [copyStatus, setCopyStatus] = useState("");

  async function copyCommand(title: string, command: string) {
    try {
      await navigator.clipboard.writeText(command);
      setCopyStatus(`${title}: command copied.`);
    } catch {
      setCopyStatus("Copy unavailable. Select the command and copy it manually.");
    }
  }

  return (
    <section className="action-quickstart" id="get-started" aria-labelledby="action-start-title">
      <div className="action-start-heading">
        <div>
          <h2 id="action-start-title">{guide.title}</h2>
          <p>{guide.description}</p>
        </div>
        <p>macOS on Apple Silicon · <a href="https://bun.sh/docs/installation">Install Bun first</a><br />No source build needed.</p>
      </div>
      <ol className="action-start-steps">
        {guide.steps.map((step, index) => (
          <li key={step.id} id={`action-start-${step.id}`}>
            <div className="action-start-instruction">
              <span className="action-start-number" aria-hidden="true">{index + 1}</span>
              <div>
                <h3>{step.title}</h3>
                <p><strong>Expect:</strong> {step.expected}</p>
              </div>
            </div>
            <div className="action-start-command">
              <pre tabIndex={0} aria-label={`${step.title} commands`}><code>{step.command}</code></pre>
              <button type="button" onClick={() => copyCommand(step.title, step.command)} aria-label={`Copy ${step.title.toLowerCase()} commands`}>Copy</button>
            </div>
          </li>
        ))}
      </ol>
      <p className="action-start-copy-status" role="status" aria-live="polite">{copyStatus}</p>
      <details className="action-start-troubleshooting">
        <summary>Something not working?</summary>
        <p>{guide.troubleshooting}</p>
      </details>
      <div className="action-start-next">
        <div>
          <h3>Next, connect your agent</h3>
          <p>{guide.agentNote}</p>
          <a href={guide.links.agents} data-router="reload">MCP setup and agent instructions</a>
        </div>
        <div>
          <h3>Working with Linux?</h3>
          <p>{guide.linuxNote}</p>
          <a href={guide.links.linux} data-router="reload">Remote Linux setup</a>
        </div>
      </div>
      <nav className="action-start-resources" aria-label="Action machine-readable documentation">
        <span>For agents</span>
        <a href={guide.links.install} data-router="reload">install.md</a>
        <a href={guide.links.instructions} data-router="reload">AGENTS.md</a>
        <a href={guide.links.index} data-router="reload">llms.txt</a>
        <a href={guide.links.manifest} data-router="reload">agent.json</a>
      </nav>
    </section>
  );
}
