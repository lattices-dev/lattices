import { useEffect, useRef, useState } from "react";
import actionDownload from "../action-download.json";
import type { MouseEvent } from "react";
import { ActionMark } from "./ActionMark";
import { actionMarkBox } from "../lib/marks";
import actionTraceField from "../../../../products/action/docs/assets/brand/landing-trace-field.webp";
import { ActionDemo } from "./ActionDemo";
import { ActionQuickStart } from "./ActionQuickStart";
import { ActionBackends, ActionEngineStrip } from "./ActionBackends";
import { actionSchema } from "../lib/action-schema";
import "../styles/action-demo.css";
import "../styles/action-standalone.css";
import { ActionArchitectureDiagram } from "./ActionArchitectureDiagram";
import { ProductsMenu, SiteFooter } from "./SiteChrome";
import { ThemeToggle } from "./ThemeToggle";

const downloadUrl = "/action/download";
const sourceUrl = "https://github.com/lattices-dev/lattices/tree/main/products/action";
const installCommand = "bun add -g @lattices/action";

export default function ActionPage() {
  const [downloadStatus, setDownloadStatus] = useState<"idle" | "loading" | "requested">("idle");
  const downloading = useRef(false);
  const downloadFrame = useRef<HTMLIFrameElement>(null);
  const [copyStatus, setCopyStatus] = useState("");

  async function copyInstallCommand() {
    try {
      await navigator.clipboard.writeText(installCommand);
      setCopyStatus("Install command copied.");
    } catch {
      setCopyStatus("Select the command to copy it manually.");
    }
  }

  async function startDownload(event: MouseEvent<HTMLAnchorElement>) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    event.preventDefault();
    const linkText = event.currentTarget.textContent || "Download Action";
    if (downloading.current) return;
    downloading.current = true;
    setDownloadStatus("loading");
    let url = actionDownload.fallbackUrl;
    try {
      const response = await fetch(actionDownload.releasesUrl, {
        headers: { Accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new Error("Release lookup failed");
      const releases = await response.json();
      const release = releases.find((release: { draft: boolean; prerelease: boolean; tag_name: string }) =>
        !release.draft && !release.prerelease && release.tag_name?.startsWith("action-v"));
      const asset = release?.assets?.find((asset: { name: string }) => asset.name === "Action.dmg");
      if (asset?.browser_download_url) url = asset.browser_download_url;
    } catch {
      // Keep the established release download available if GitHub's API is unavailable.
    }
    if (downloadFrame.current) downloadFrame.current.src = url;
    window.gtag?.("event", "file_download", {
      file_name: "Action.dmg", file_extension: "dmg", link_url: url,
      link_text: linkText,
      product: "action",
    });
    setDownloadStatus("requested");
    downloading.current = false;
  }

  const [theme, setTheme] = useState<"light" | "dark">(() => {
    if (typeof document === "undefined") return "dark";
    return (document.documentElement.getAttribute("data-theme") as "light" | "dark") || "dark";
  });

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("theme", theme);
  }, [theme]);

  return (
    <div className="action-page">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(actionSchema()).replace(/</g, "\\u003c") }} />
      <link rel="describedby" type="text/plain" href="/action/docs/llms.txt" title="Action agent documentation" />
      <link rel="describedby" type="application/json" href="/action/agent.json" />
      <iframe ref={downloadFrame} title="Action download" hidden />
      {downloadStatus !== "idle" && (
        <aside className="action-download-notice" role="status" aria-live="polite">
          <div>
            <strong>{downloadStatus === "loading" ? "Preparing your download…" : "Your Action download has been requested."}</strong>
            <p>{downloadStatus === "loading" ? "Finding the latest release for macOS." : "Check your browser downloads."}</p>
            {downloadStatus === "requested" && <a href={downloadUrl} data-router="reload" target="_blank" rel="noopener noreferrer">If the download did not start, try again ↗</a>}
          </div>
          <button type="button" onClick={() => setDownloadStatus("idle")} aria-label="Dismiss download message">×</button>
        </aside>
      )}
      <nav className="nav action-nav" aria-label="Action navigation">
        <div className="nav-inner">
          <a href="/action" className="nav-brand action-product-brand" aria-label="Action home">
            <ActionMark
              palette={{ ink: "currentColor" }}
              guides={false}
              background={false}
              viewBox={actionMarkBox.join(" ")}
              decorative
              style={{ width: 26, height: 26 }}
            />
            <span className="nav-name">action</span>
          </a>
          <div className="nav-links">
            <ProductsMenu />
            <a href="#backends" className="nav-link action-nav-engines">Engines</a>
            <a href="/action/docs" className="nav-link action-nav-optional">Docs</a>
            <a href={sourceUrl} className="nav-link action-nav-source">Source</a>
            <ThemeToggle
              theme={theme}
              onToggle={() => setTheme(theme === "dark" ? "light" : "dark")}
            />
            <a href={downloadUrl} data-router="reload" onClick={startDownload} className="action-nav-download">Download</a>
          </div>
        </div>
      </nav>

      <main className="action-shell">
        <section className="action-demo-hero" aria-labelledby="action-title">
          <div className="action-demo-intro action-standalone-intro">
            <div>
              <h1 id="action-title">An API for agents to use your computer.</h1>
              <p className="action-demo-lead">
                A standalone CLI, MCP server and native Mac app. Give your agent computer use through the engine you choose.
              </p>
            </div>
            <div className="action-demo-install action-standalone-install">
              <div className="action-install-command">
                <code>{installCommand}</code>
                <button type="button" onClick={copyInstallCommand} aria-label="Copy Action install command">Copy</button>
              </div>
              <div className="action-hero-actions">
                <a href="#get-started" className="hero-primary-cta action-primary-cta">
                  Get started
                  <span aria-hidden="true">↗</span>
                </a>
                <a href={downloadUrl} data-router="reload" onClick={startDownload} className="hero-secondary-cta action-secondary-cta">
                  Download Mac app
                </a>
              </div>
              <p className="action-demo-platform">macOS · CLI, MCP &amp; TypeScript · Install independently</p>
              <p className="action-install-status" role="status" aria-live="polite">{copyStatus}</p>
            </div>
          </div>
          <ActionEngineStrip />
          <ActionDemo />
        </section>

        <ActionBackends />

        <div className="action-standalone-start"><ActionQuickStart /></div>

        <div className="action-tech-rail" aria-label="Core technologies">
          <span>AppKit lifecycle</span>
          <span>ScreenCaptureKit</span>
          <span>AX + OCR</span>
          <span>CLI + MCP</span>
        </div>

        <section id="architecture" className="action-architecture" aria-labelledby="action-architecture-title">
          <div className="action-architecture-copy">
            <h2 id="action-architecture-title">
              <span>Inside Action’s</span>
              <span>native engine.</span>
            </h2>
            <p>
              With Action’s native engine, an agent or operator calls the local runtime. It owns sessions, targets and orchestration, while ActionAgent bridges requests into native macOS work.
            </p>
            <p>
              Action.app owns AppKit, WebKit, permissions, and capture. The run comes back with its receipts attached, including an explicit finished marker when recording is actually complete.
            </p>
          </div>
          <ActionArchitectureDiagram theme={theme} />
        </section>

        <section className="action-proof" aria-labelledby="action-proof-title">
          <img className="action-proof-art" src={actionTraceField} alt="" aria-hidden="true" />
          <div className="action-proof-inner">
            <div className="action-section-heading">
              <h2 id="action-proof-title">See what happened.</h2>
              <p>
                Action’s native runtime keeps screenshots and an activity log with each session. When you record a run, it also tracks when capture has finished.
              </p>
            </div>
            <div className="action-proof-lines">
              <article>
                <span>01</span>
                <h3>Find the right control</h3>
                <p>Action finds buttons and fields through Accessibility and the browser DOM before falling back to screen coordinates.</p>
              </article>
              <article>
                <span>02</span>
                <h3>Run on the Mac</h3>
                <p>Action uses AppKit and ScreenCaptureKit, with access controlled by your macOS permissions.</p>
              </article>
              <article>
                <span>03</span>
                <h3>Review the recording</h3>
                <p>A recorded native session keeps its video, screenshots, activity log, and capture completion status together.</p>
              </article>
            </div>
          </div>
        </section>

        <section className="action-source" aria-labelledby="action-source-title">
          <div className="action-source-copy">
            <h2 id="action-source-title">Build it. Launch it. Prove it.</h2>
            <p>
              Local commands live in <code>package.json</code>. Run them with bun from <code>products/action</code>.
            </p>
            <ul className="action-source-reqs">
              <li>macOS on Apple Silicon</li>
              <li>Bun and the Swift toolchain</li>
              <li>Accessibility permission</li>
              <li>Screen Recording permission</li>
            </ul>
            <a href="/action/getting-started.md" data-router="reload" className="action-source-link">Getting started &rarr;</a>
          </div>
          <div className="action-terminal" aria-label="Action source commands">
            <div className="action-terminal-bar">products/action</div>
            <pre className="action-terminal-body">
              <code>
                <span className="action-terminal-line"><span className="action-terminal-prompt">$</span> bun install</span>
                <span className="action-terminal-line"><span className="action-terminal-prompt">$</span> bun run native:app:build</span>
                <span className="action-terminal-output">Action.app signed and ready</span>
                <span className="action-terminal-line"><span className="action-terminal-prompt">$</span> bun run native:doctor</span>
                <span className="action-terminal-output">Accessibility: granted · Screen Recording: granted</span>
                <span className="action-terminal-line"><span className="action-terminal-prompt">$</span> bun run native:launch</span>
                <span className="action-terminal-output">Action.app running</span>
              </code>
            </pre>
          </div>
        </section>

        <section className="action-final-cta" aria-labelledby="action-final-title">
          <div className="action-final-copy">
            <h2 id="action-final-title">Give the agent a computer-use path you can review.</h2>
            <div className="action-final-links">
              <a href={downloadUrl} data-router="reload" onClick={startDownload} className="hero-primary-cta action-primary-cta">Download Action</a>
              <a href={sourceUrl} className="hero-secondary-cta action-secondary-cta">View source</a>
            </div>
            <p className="action-family-note">Part of the <a href="/">Lattices family</a>. Install and use Action on its own.</p>
          </div>
          <figure className="action-brand-study" aria-hidden="true">
            <ActionMark theme={theme} padding={36} decorative />
          </figure>
        </section>
      </main>

      <SiteFooter current="/action" />
    </div>
  );
}
