import type { Display } from "./model";

/** Small, intentionally schematic desktops. All contents are demo fixtures. */
export function DesktopPreview({ scene, wireframe = false }: { scene: Display["scene"]; wireframe?: boolean }) {
  return <div className={`lt-desktop lt-desktop--${scene}${wireframe ? " lt-desktop--wireframe" : ""}`} aria-hidden="true">
    <div className="lt-desktop-menu"><span>Lattices</span><span>File　Edit　View</span><span>13:04</span></div>
    {scene === "browser" ? <div className="lt-browser-demo"><div>lattices.app / docs</div><h4>Your workspace,<br />programmable.</h4><p>Windows. Layers. Connected computers.</p><section><span>Getting started</span><span>Arrange your workspace</span><span>Connect a computer</span></section></div> : scene === "landscape" ? <>
      <div className="lt-landscape"><i /><i /><i /><i /></div>
      <div className="lt-dock">{Array.from({ length: 7 }, (_, i) => <i key={i} />)}</div>
    </> : <div className="lt-demo-windows">
      <div className="lt-demo-window lt-demo-window--primary">
        <div className="lt-demo-title"><i /><i /><i /><span>{scene === "code" ? "RemoteSession.swift" : "fab — workspace"}</span></div>
        <div className="lt-code-gutter"><span>01<br />02<br />03<br />04<br />05<br />06<br />07<br />08</span><div>
          <b>{scene === "code" ? "struct Workspace {" : "~/dev/fab  main"}</b>
          <p>{scene === "code" ? "  let displays: [Display]" : "$ bun run dev"}</p>
          <p className="lt-code-muted">{scene === "code" ? "  var selected: Host?" : "  workspace ready"}</p>
          <p>{scene === "code" ? "  func arrange() {" : "  watching for changes…"}</p>
          <p className="lt-code-muted">{scene === "code" ? "    layout.apply()" : "  connected to desk"}</p>
          <p>{scene === "code" ? "  }" : "❯"}</p>
        </div></div>
      </div>
      <div className="lt-demo-window lt-demo-window--secondary">
        <div className="lt-demo-title"><i /><i /><i /><span>{scene === "windows" ? "mini: fab · desk" : "Workspace"}</span></div>
        <div className="lt-mini-content"><b>{scene === "windows" ? "Ready for your next idea." : "Your workspace,"}<br />{scene !== "windows" && "programmable."}</b><span /><span /><span /><div className="lt-mini-grid"><i /><i /><i /><i /><i /><i /></div></div>
      </div>
    </div>}
  </div>;
}
