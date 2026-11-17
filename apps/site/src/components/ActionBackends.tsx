import { ActionMark } from "./ActionMark";
import { CuaMark, OpenAIMark } from "./BackendMarks";
import { actionMarkBox } from "../lib/marks";

export function ActionEngineStrip() {
  return (
    <div className="action-engine-strip" aria-label="Supported computer-use engines">
      <span className="action-engine-strip-label">Works with</span>
      <a href="#backends">
        <OpenAIMark className="action-provider-mark" />
        <span>Codex Computer Use<span className="action-provider-byline">OpenAI</span></span>
      </a>
      <a href="#backends">
        <CuaMark />
        <span>Cua Driver<span className="action-provider-byline">Cua / trycua</span></span>
      </a>
      <a className="action-engine-native-link" href="#native-engine">And Action’s own native engine <span aria-hidden="true">↗</span></a>
    </div>
  );
}

export function ActionBackends() {
  return (
    <section id="backends" className="action-backends" aria-labelledby="action-backends-title">
      <div className="action-backends-heading">
        <h2 id="action-backends-title">Your engine.<br /> The same Action.</h2>
        <p>Use Action’s native Mac engine, or connect Codex Computer Use or Cua Driver. Install the CLI once and add the companion app for your chosen engine. Each works through the same CLI, MCP server and TypeScript API.</p>
      </div>

      <div className="action-engine-list">
        <article className="action-engine-row" id="native-engine">
          <div className="action-engine-identity">
            <ActionMark palette={{ ink: "currentColor" }} guides={false} background={false} viewBox={actionMarkBox.join(" ")} decorative style={{ width: 40, height: 40 }} />
            <div><h3>Action native</h3><p>Built into Action.app</p></div>
          </div>
          <p>Control Mac apps through Accessibility. Add native screenshots, recording and a live view of the agent’s workspace with the Action runtime.</p>
          <div className="action-engine-command"><code>action setup action-cua</code><span>Requires Action.app</span></div>
        </article>
        <article className="action-engine-row">
          <div className="action-engine-identity">
            <OpenAIMark className="action-provider-mark" />
            <div><h3>Codex Computer Use</h3><p>OpenAI</p></div>
          </div>
          <p>Bring the computer-use engine from the ChatGPT desktop app into your Action workflow.</p>
          <div className="action-engine-command"><code>action setup codex-cua</code><span>Requires the Computer Use plugin</span></div>
        </article>
        <article className="action-engine-row">
          <div className="action-engine-identity">
            <CuaMark />
            <div><h3>Cua Driver</h3><p>Cua / trycua</p></div>
          </div>
          <p>Connect Cua’s local Mac driver for Accessibility actions, screenshots, keyboard and pointer input.</p>
          <div className="action-engine-command"><code>action setup trycua-cua</code><span>Requires CuaDriver.app and cua-driver</span></div>
        </article>
      </div>

      <div className="action-engine-control">
        <h3>You choose what can take control.</h3>
        <div>
          <p>Observe and semantic Accessibility actions are enabled by default. Keyboard and pointer input require explicit permission with <code>--allow attention</code>.</p>
          <p>You select the engine for every command. <a href="https://www.npmjs.com/package/@lattices/action">Compare actions and engine requirements <span aria-hidden="true">↗</span></a></p>
        </div>
      </div>
    </section>
  );
}
