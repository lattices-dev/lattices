import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import "../styles/hero-control.css";

const subjects = ["workspace", "windows", "terminals", "projects"];
const motionPreference = "(prefers-reduced-motion: reduce)";
const readMotionPreference = () => window.matchMedia(motionPreference).matches;
const staticMotionPreference = () => true;

function subscribeToMotionPreference(onChange: () => void) {
  const query = window.matchMedia(motionPreference);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

const harnesses = [
  {
    id: "claude",
    name: "Claude Code",
    request: "Put my project’s windows side by side.",
    description: "With the Lattices skill, Claude Code can find and arrange your project’s windows.",
  },
  {
    id: "codex",
    name: "Codex",
    request: "Find the terminal running my dev server.",
    description: "With the Lattices skill, Codex can search your terminal sessions and bring the right one into focus.",
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    request: "Open a terminal for this project.",
    description: "With the Lattices skill, Gemini CLI can start a project session and place its terminal window.",
  },
  {
    id: "opencode",
    name: "OpenCode",
    request: "Bring my workspace back into place.",
    description: "With the Lattices skill, OpenCode can apply a saved layer to arrange your workspace.",
  },
];

/** One stable headline for readers, with examples for visitors who want motion. */
export function HeroControlHeadline() {
  const reducedMotion = useSyncExternalStore(subscribeToMotionPreference, readMotionPreference, staticMotionPreference);
  const rootRef = useRef<HTMLDivElement>(null);
  const [subjectIndex, setSubjectIndex] = useState(0);
  const [paused, setPaused] = useState(false);
  const [inView, setInView] = useState(true);
  const [pageVisible, setPageVisible] = useState(true);
  const [activeHarness, setActiveHarness] = useState<string | null>(null);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const observer = new IntersectionObserver(([entry]) => setInView(entry.isIntersecting));
    observer.observe(root);
    const onVisibility = () => setPageVisible(!document.hidden);
    const onOutsidePointer = (event: PointerEvent) => {
      if (!root.contains(event.target as Node)) setActiveHarness(null);
    };
    const onEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setActiveHarness(null);
    };
    onVisibility();
    document.addEventListener("visibilitychange", onVisibility);
    document.addEventListener("pointerdown", onOutsidePointer);
    document.addEventListener("keydown", onEscape);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
      document.removeEventListener("pointerdown", onOutsidePointer);
      document.removeEventListener("keydown", onEscape);
    };
  }, []);

  useEffect(() => {
    if (reducedMotion || paused || !inView || !pageVisible || activeHarness) return;
    const timer = window.setTimeout(
      () => setSubjectIndex((index) => (index + 1) % subjects.length),
      subjectIndex === 0 ? 5200 : 3200,
    );
    return () => window.clearTimeout(timer);
  }, [reducedMotion, paused, inView, pageVisible, activeHarness, subjectIndex]);

  const visibleSubject = reducedMotion ? 0 : subjectIndex;

  return (
    <div className="hero-control" ref={rootRef}>
      <h1 className="hero-control-title">
        <span className="sr-only">Take control of your workspace.</span>
        <span aria-hidden="true">
          <span className="hero-control-first-line">Take control of</span>
          <span className="hero-control-second-line">
            your{" "}
            <span className="hero-control-subject">
              {subjects.map((subject, index) => (
                <span key={subject} className={index === visibleSubject ? "is-current" : ""}>
                  {subject}<span className="hero-control-period">.</span>
                </span>
              ))}
            </span>
          </span>
        </span>
      </h1>

      <div className="hero-control-harnesses" role="group" aria-label="Explore workspace controls for your agent">
        {harnesses.map((harness) => {
          const active = activeHarness === harness.id;
          return (
            <div
              key={harness.id}
              className={`hero-control-harness hero-control-harness-${harness.id}${active ? " is-active" : ""}`}
              onPointerEnter={(event) => {
                if (event.pointerType !== "touch") setActiveHarness(harness.id);
              }}
              onPointerLeave={(event) => {
                if (!event.currentTarget.contains(document.activeElement)) setActiveHarness(null);
              }}
              onBlur={(event) => {
                if (!event.currentTarget.contains(event.relatedTarget)) setActiveHarness(null);
              }}
            >
              <button
                type="button"
                className="hero-control-agent"
                aria-label={`${harness.name} workspace controls`}
                aria-describedby={active ? `hero-agent-${harness.id}` : undefined}
                onFocus={() => setActiveHarness(harness.id)}
                onClick={() => setActiveHarness(harness.id)}
              >
                <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
                  <path d="m4 6 4 4-4 4m7 0h5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
                {harness.name}
                <span className="hero-control-agent-indicator" aria-hidden="true" />
              </button>
              <div id={`hero-agent-${harness.id}`} className="hero-control-tooltip" role="tooltip" hidden={!active}>
                <p className="hero-control-request">“{harness.request}”</p>
                <p>{harness.description}</p>
                <span>Same controls. With access you choose.</span>
              </div>
            </div>
          );
        })}
      </div>

      {!reducedMotion && (
        <button
          type="button"
          className="hero-control-motion"
          aria-label={paused ? "Resume rotating words" : "Pause rotating words"}
          aria-pressed={paused}
          onClick={() => setPaused((value) => !value)}
        >
          <svg viewBox="0 0 16 16" fill="none" aria-hidden="true">
            {paused
              ? <path d="m5.5 3 7 5-7 5Z" fill="currentColor" />
              : <path d="M5.5 4v8m5-8v8" stroke="currentColor" strokeWidth="2" />}
          </svg>
        </button>
      )}
    </div>
  );
}
