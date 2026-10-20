/** Runtime boundaries in Lattices 0.15.1, Action 0.4.0 and Speech 0.3.0. */
export function MacRuntimeDiagram() {
  return (
    <figure className="runtime-map" aria-label="macOS runtime boundaries: private local IPC and an optional remote gateway">
      <section className="runtime-process" style={{ gridColumn: '1 / -1' }}>
        <h3>Remote gateway <span>Separate process, started explicitly</span></h3>
        <p>Tailscale identity, signed requests, and approved product/method grants</p>
        <dl>
          <div><dt>Remote RPC and companion relay</dt><dd>Tailscale <code>:9399</code></dd></div>
          <div><dt>Local gateway control</dt><dd><code>gateway.sock</code></dd></div>
        </dl>
        <p className="runtime-entry">Approved remote calls reach product sockets below. Local clients connect directly to those sockets.</p>
      </section>
      <div className="runtime-map-main">
        <section className="runtime-process">
          <h3>Lattices.app</h3>
          <p>Workspace, windows, layers, and sessions</p>
          <dl>
            <div><dt>Agent API</dt><dd><code>lattices.sock</code></dd></div>
            <div><dt>Voice input, local only</dt><dd><code>voice.sock</code></dd></div>
            <div><dt>Companion bridge</dt><dd><code>companion.sock</code></dd></div>
          </dl>
          <p className="runtime-entry"><code>lats</code> and local scripts use private IPC. Remote companion clients use the gateway relay and their separate device pairing.</p>
        </section>
        <div className="runtime-connector">
          <span><code>voice.*</code> forwards playback requests</span>
          <svg viewBox="0 0 20 32" width="20" height="32" aria-hidden="true"><path d="M10 1v27m-5-5 5 5 5-5" /></svg>
        </div>
        <section className="runtime-process">
          <h3>Voice.app <span>Speech</span></h3>
          <p>Synthesis, playback queue, and readalong</p>
          <dl><div><dt>Authenticated Speech API</dt><dd><code>speech.sock</code></dd></div></dl>
          <p className="runtime-entry">Also accepts direct <code>speech.*</code> clients</p>
        </section>
      </div>
      <div className="runtime-map-peers">
        <section className="runtime-process">
          <h3>Action.app <span>+ helper processes</span></h3>
          <p>Observe, resolve, act, and record</p>
          <dl>
            <div><dt>ActionAgent.app</dt><dd><code>action.sock</code></dd></div>
            <div><dt>Chrome bridge</dt><dd><code>action-chrome.sock</code></dd></div>
            <div><dt>Job service, in Action support</dt><dd><code>runtime/companion.sock</code></dd></div>
          </dl>
          <p className="runtime-entry"><code>lats action</code> calls the agent directly. The Chrome native messaging host connects to the Chrome bridge. Recording probes and the durable job service keep separate processes.</p>
        </section>
        <section className="runtime-process">
          <h3>Canvas.app <span>Spatial notes</span></h3>
          <p>Note panels and named desks</p>
          <dl><div><dt>Local interfaces</dt><dd>Files + <code>blink.sock</code></dd></div></dl>
          <p className="runtime-entry"><code>canvas</code> CLI, note files, socket clients</p>
        </section>
      </div>
      <figcaption>Lattices 0.15.1, Action 0.4.0, Speech 0.3.0 and Canvas 2.3.0. Products keep separate app lifecycles and do not start the gateway. The playback bridge passes through the local Lattices API; voice input stays local. Action-owned Chrome retains its separate loopback CDP listener.</figcaption>
    </figure>
  )
}

export function LinuxRuntimeDiagram() {
  return (
    <figure className="runtime-map runtime-map-linux" aria-label="Linux runtime boundaries: local host sockets and a separate remote gateway">
      <div className="runtime-linux-clients">
        <span>Quickshell backend and tray</span><span><code>lats</code> CLI</span>
      </div>
      <div className="runtime-connector">
        <span>Authenticated local WebSocket over Unix socket</span>
        <svg viewBox="0 0 20 32" width="20" height="32" aria-hidden="true"><path d="M10 1v27m-5-5 5 5 5-5" /></svg>
      </div>
      <section className="runtime-process">
        <h3>lattices-host <span>Bun service</span></h3>
        <p>Hyprland backend for windows, workspaces, and computer use</p>
        <dl><div><dt>Host API</dt><dd><code>lattices.sock</code></dd></div><div><dt>Companion bridge</dt><dd><code>companion.sock</code></dd></div></dl>
      </section>
      <div className="runtime-connector">
        <span>Approved RPC calls and authenticated companion relay use private IPC</span>
        <svg viewBox="0 0 20 32" width="20" height="32" aria-hidden="true"><path d="M10 31V4m-5 5 5-5 5 5" /></svg>
      </div>
      <section className="runtime-process">
        <h3>Remote gateway <span>Separate, opt-in process</span></h3>
        <dl><div><dt>Tailscale network listener</dt><dd><code>:9399</code> by default</dd></div></dl>
        <p className="runtime-entry">Remote clients require Tailscale identity and pairing. Action RemoteEngine requests reach the host only with approved grants.</p>
      </section>
      <figcaption>Lattices 0.15.1 architecture; the macOS rollout does not verify Linux runtime behavior. The Linux UI, host, and gateway are separate processes. The host has no TCP compatibility listener.</figcaption>
    </figure>
  )
}
