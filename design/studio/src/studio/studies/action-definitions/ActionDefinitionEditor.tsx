"use client";

import { useMemo, useState } from "react";

export type ActionEditorTone = "lattices" | "talkie";
export type ActionEditorScene =
  | "draft"
  | "clarify"
  | "ready"
  | "partial"
  | "unavailable"
  | "failed"
  | "tested"
  | "empty";

type Capability = "available" | "degraded" | "unavailable";

interface ActionStep {
  id: string;
  verb: string;
  target: string;
  placement: string;
  capability: Capability;
}

interface ActionDefinition {
  id: string;
  name: string;
  phrases: string[];
  description: string;
  steps: ActionStep[];
}

interface ActionDefinitionEditorProps {
  tone: ActionEditorTone;
  scene: ActionEditorScene;
  onSceneChange: (scene: ActionEditorScene) => void;
}

const initialDefinitions: ActionDefinition[] = [
  {
    id: "review-release",
    name: "Review release",
    phrases: ["Review the release"],
    description: "Open the latest release, place my code beside it, and keep the logs visible.",
    steps: [
      { id: "release", verb: "Open", target: "Latest release", placement: "Left half", capability: "available" },
      { id: "code", verb: "Place", target: "Current code window", placement: "Upper right", capability: "available" },
      { id: "logs", verb: "Keep", target: "Terminal logs", placement: "Lower right", capability: "available" },
    ],
  },
  {
    id: "focus-writing",
    name: "Focus writing",
    phrases: ["Set up writing"],
    description: "Bring the draft forward and move everything else out of the way.",
    steps: [
      { id: "draft", verb: "Focus", target: "Current draft", placement: "Center", capability: "available" },
      { id: "others", verb: "Move", target: "Other windows", placement: "Next space", capability: "available" },
    ],
  },
  {
    id: "standup-view",
    name: "Standup view",
    phrases: ["Show my standup"],
    description: "Arrange the issue tracker, terminal, and notes for the morning standup.",
    steps: [
      { id: "issues", verb: "Place", target: "Issue tracker", placement: "Left half", capability: "available" },
      { id: "terminal", verb: "Place", target: "Terminal", placement: "Upper right", capability: "available" },
      { id: "notes", verb: "Place", target: "Standup notes", placement: "Lower right", capability: "available" },
    ],
  },
];

/* The blocked step is named once so the row, the preview tile and the
   callout cannot drift apart. */
const BLOCKED_TARGET = "GitHub unavailable";

const sceneLabels: Record<ActionEditorScene, string> = {
  draft: "Draft",
  clarify: "Needs detail",
  ready: "Ready",
  partial: "Limited",
  unavailable: "Blocked step",
  failed: "Test failed",
  tested: "Test passed",
  empty: "Empty",
};

function Icon({ name }: { name: "action" | "search" | "voice" | "play" | "plus" | "more" | "check" | "alert" | "trash" | "chevron" }) {
  const paths = {
    action: <><path d="M7 3h8l4 4v14H7z"/><path d="M15 3v5h5M10 12h6M10 16h6"/></>,
    search: <><circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/></>,
    voice: <><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6 11a6 6 0 0 0 12 0M12 17v4M9 21h6"/></>,
    play: <path d="m9 7 8 5-8 5z"/>,
    plus: <path d="M12 5v14M5 12h14"/>,
    more: <><circle cx="6" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="18" cy="12" r="1" fill="currentColor" stroke="none"/></>,
    check: <path d="m5 12 4 4L19 6"/>,
    alert: <><path d="M12 3 2.7 20h18.6z"/><path d="M12 9v5M12 17.2v.1"/></>,
    trash: <><path d="M5 7h14M9 7V4h6v3M7 7l1 14h8l1-14"/></>,
    chevron: <path d="m9 5 7 7-7 7"/>,
  };
  return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">{paths[name]}</svg>;
}

function capabilityForScene(step: ActionStep, index: number, scene: ActionEditorScene): Capability {
  if (scene === "unavailable" && index === 0) return "unavailable";
  if (scene === "partial" && index === 2) return "degraded";
  return step.capability;
}

function WorkspacePreview({ steps, scene }: { steps: ActionStep[]; scene: ActionEditorScene }) {
  return (
    <div className="action-preview__display" aria-label="Illustrative workspace preview">
      <div className="action-preview__menubar"><span /><span /></div>
      <div className="action-preview__desktop">
        {steps.map((step, index) => {
          const capability = capabilityForScene(step, index, scene);
          return (
            <div key={step.id} className={`action-preview__window action-preview__window--${index + 1}`} data-capability={capability}>
              <span className="action-preview__window-index">{index + 1}</span>
              <span>{capability === "unavailable" ? BLOCKED_TARGET : step.target}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export function ActionDefinitionEditor({ tone, scene, onSceneChange }: ActionDefinitionEditorProps) {
  const [definitions, setDefinitions] = useState(initialDefinitions);
  const [selectedID, setSelectedID] = useState(initialDefinitions[0].id);
  const [query, setQuery] = useState("");
  const [reuseWindows, setReuseWindows] = useState(true);
  const [preserveWork, setPreserveWork] = useState(true);
  const [activeStepID, setActiveStepID] = useState("code");
  const [isListening, setIsListening] = useState(false);
  const [isSaved, setIsSaved] = useState(false);
  const [isRestored, setIsRestored] = useState(false);

  const sceneDefinitions = useMemo(
    () => (scene === "empty" ? [] : definitions),
    [definitions, scene],
  );
  const visibleDefinitions = useMemo(
    () => sceneDefinitions.filter((item) => `${item.name} ${item.phrases.join(" ")}`.toLowerCase().includes(query.toLowerCase())),
    [sceneDefinitions, query],
  );
  const selected = sceneDefinitions.find((item) => item.id === selectedID);

  const updateSelected = (patch: Partial<ActionDefinition>) => {
    setDefinitions((items) => items.map((item) => item.id === selectedID ? { ...item, ...patch } : item));
    setIsSaved(false);
  };

  const createAction = () => {
    const id = `action-${Date.now()}`;
    const next: ActionDefinition = { id, name: "Untitled action", phrases: [""], description: "", steps: [] };
    setDefinitions((items) => [...items, next]);
    setSelectedID(id);
    setActiveStepID("");
    setIsSaved(false);
    onSceneChange("draft");
  };

  const deleteAction = () => {
    if (!selected) return;
    const remaining = definitions.filter((item) => item.id !== selected.id);
    setDefinitions(remaining);
    setSelectedID(remaining[0]?.id ?? "");
    setActiveStepID(remaining[0]?.steps[0]?.id ?? "");
    onSceneChange(remaining.length ? "draft" : "empty");
  };

  const addPhrase = () => selected && updateSelected({ phrases: [...selected.phrases, "Another phrase"] });
  const updatePhrase = (index: number, value: string) => selected && updateSelected({ phrases: selected.phrases.map((phrase, i) => i === index ? value : phrase) });
  const removePhrase = (index: number) => selected && updateSelected({ phrases: selected.phrases.filter((_, i) => i !== index) });

  const addStep = () => {
    if (!selected) return;
    const id = `step-${Date.now()}`;
    updateSelected({ steps: [...selected.steps, { id, verb: "Open", target: "Choose a window", placement: "Center", capability: "available" }] });
    setActiveStepID(id);
  };

  const updateStep = (id: string, patch: Partial<ActionStep>) => selected && updateSelected({
    steps: selected.steps.map((step) => step.id === id ? { ...step, ...patch } : step),
  });

  const moveStep = (id: string, offset: -1 | 1) => {
    if (!selected) return;
    const index = selected.steps.findIndex((step) => step.id === id);
    const target = index + offset;
    if (index < 0 || target < 0 || target >= selected.steps.length) return;
    const steps = [...selected.steps];
    [steps[index], steps[target]] = [steps[target], steps[index]];
    updateSelected({ steps });
  };

  const deleteStep = (id: string) => {
    if (!selected) return;
    const steps = selected.steps.filter((step) => step.id !== id);
    updateSelected({ steps });
    setActiveStepID(steps[0]?.id ?? "");
  };

  const resolveClarification = (askEveryTime: boolean) => {
    if (!selected) return;
    const first = selected.steps[0];
    if (first) updateStep(first.id, { target: askEveryTime ? "Release page (ask each time)" : "GitHub releases" });
    onSceneChange("ready");
  };

  const runTest = () => {
    setIsRestored(false);
    if (scene === "unavailable") onSceneChange("partial");
    else if (scene === "failed") onSceneChange("tested");
    else onSceneChange("tested");
  };

  return (
    <section className="action-editor" data-tone={tone} data-scene={scene}>
      <header className="action-editor__bar">
        <div className="action-editor__identity">
          <span className="action-editor__mark"><Icon name="action" /></span>
          <div><strong>Actions</strong><span>Workspace definitions</span></div>
        </div>
        <div className="action-editor__context">Definition editor</div>
        <button className="action-control action-control--quiet" type="button" aria-label="More options"><Icon name="more" /></button>
      </header>

      <div className="action-editor__body">
        <aside className="action-library">
          <div className="action-search">
            <Icon name="search" />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find an action" aria-label="Find an action" />
          </div>
          <div className="action-library__heading">
            <span>Your actions</span>
            <button type="button" aria-label="Create action" onClick={createAction}><Icon name="plus" /></button>
          </div>
          <div className="action-library__list">
            {visibleDefinitions.map((item) => (
              <button key={item.id} type="button" className="action-library__item" aria-current={item.id === selected?.id ? "true" : undefined} onClick={() => { setSelectedID(item.id); setActiveStepID(item.steps[0]?.id ?? ""); onSceneChange("draft"); }}>
                <span className="action-library__glyph"><Icon name="action" /></span>
                <span><strong>{item.name}</strong><small>“{item.phrases.find((phrase) => phrase.trim()) || "No trigger yet"}”</small></span>
              </button>
            ))}
            {!visibleDefinitions.length ? (
              <p className="action-library__empty">
                {sceneDefinitions.length ? "No matching actions" : "No actions on this Mac yet"}
              </p>
            ) : null}
          </div>
          <div className="action-library__footer" data-empty={sceneDefinitions.length ? undefined : "true"}>
            <span className="action-library__pulse" />
            {sceneDefinitions.length} available on this Mac
          </div>
        </aside>

        {selected ? (
          <>
            <section className="action-definition">
              <header className="action-definition__header">
                <div className="action-definition__heading">
                  <div className="action-definition__title-row">
                    <input value={selected.name} onChange={(event) => updateSelected({ name: event.target.value })} aria-label="Action name" />
                    <span className="action-state">{isSaved ? "Saved" : sceneLabels[scene]}</span>
                  </div>
                  <p>Describe the result. Lattices resolves the current workspace when the action runs.</p>
                </div>
                <div className="action-definition__actions">
                  <button className="action-control action-control--danger" type="button" onClick={deleteAction} aria-label="Delete action"><Icon name="trash" /></button>
                  <button className="action-control" type="button" onClick={runTest}><Icon name="play" /> {scene === "failed" ? "Retry" : scene === "unavailable" ? "Run available" : "Test"}</button>
                  <button className="action-control action-control--primary" type="button" onClick={() => setIsSaved(true)}>Save action</button>
                </div>
              </header>

              <div className="action-definition__scroll">
                <section className="action-intent">
                  <div className="action-section-heading"><span>Describe the outcome</span><span>{isListening ? "Listening…" : "Natural language"}</span></div>
                  <div className="action-intent__field" data-listening={isListening || undefined}>
                    <button type="button" aria-label={isListening ? "Stop listening" : "Define with voice"} onClick={() => setIsListening((value) => !value)}><Icon name="voice" /></button>
                    <textarea value={selected.description} onChange={(event) => updateSelected({ description: event.target.value })} placeholder="What should the workspace look like when this is done?" aria-label="Action description" />
                    <button type="button" onClick={() => onSceneChange(selected.description.toLowerCase().includes("latest") ? "clarify" : "ready")}>Interpret</button>
                  </div>
                  {scene === "clarify" ? (
                    <div className="action-clarification">
                      <span>One detail needed</span><strong>Which release page should “latest” use?</strong>
                      <div><button type="button" onClick={() => resolveClarification(false)}>GitHub releases</button><button type="button" onClick={() => resolveClarification(true)}>Ask each time</button></div>
                    </div>
                  ) : null}
                  {scene === "unavailable" ? (
                    <div className="action-capability action-capability--blocked"><Icon name="alert" /><div><strong>{BLOCKED_TARGET}</strong><span>The rest of this action can still run. Choose a browser fallback or skip this step.</span></div><button type="button" onClick={() => { updateStep(selected.steps[0]?.id ?? "", { target: "Release page in browser" }); onSceneChange("partial"); }}>Use browser</button></div>
                  ) : null}
                  {scene === "partial" ? (
                    <div className="action-capability"><Icon name="alert" /><div><strong>Runs with one adjustment</strong><span>Terminal matching is unavailable, so any open terminal will be kept visible.</span></div><button type="button" onClick={() => onSceneChange("ready")}>Accept</button></div>
                  ) : null}
                </section>

                <section className="action-section">
                  <div className="action-section-heading"><span>Triggers</span><button type="button" onClick={addPhrase}>+ Add phrase</button></div>
                  <div className="action-triggers">
                    {selected.phrases.map((phrase, index) => (
                      <div className="action-trigger" key={`${selected.id}-phrase-${index}`}>
                        <span>{index === 0 ? "When I say" : "Or"}</span>
                        <input value={phrase} onChange={(event) => updatePhrase(index, event.target.value)} aria-label={`Trigger phrase ${index + 1}`} placeholder="Add a spoken phrase" />
                        {selected.phrases.length > 1 ? <button type="button" onClick={() => removePhrase(index)} aria-label={`Remove trigger phrase ${index + 1}`}>×</button> : null}
                      </div>
                    ))}
                  </div>
                </section>

                <section className="action-section">
                  <div className="action-section-heading"><span>Outcome</span><button type="button" onClick={addStep}>+ Add step</button></div>
                  <div className="action-steps">
                    {selected.steps.map((step, index) => {
                      const capability = capabilityForScene(step, index, scene);
                      return (
                        <div key={step.id} className="action-step-wrap" data-capability={capability}>
                          <button
                            type="button"
                            className="action-step"
                            aria-current={activeStepID === step.id ? "step" : undefined}
                            aria-expanded={activeStepID === step.id}
                            onClick={() => setActiveStepID(activeStepID === step.id ? "" : step.id)}
                          >
                            <span className="action-step__number">{index + 1}</span>
                            <span className="action-step__verb">{step.verb}</span>
                            <strong>{capability === "unavailable" ? BLOCKED_TARGET : step.target}</strong>
                            <span className="action-step__placement">{capability === "degraded" ? "Any match" : step.placement}</span>
                            <span className="action-step__chevron" data-open={activeStepID === step.id || undefined}><Icon name="chevron" /></span>
                          </button>
                          {activeStepID === step.id ? (
                            <div className="action-step-editor">
                              <label><span>Action</span><select value={step.verb} onChange={(event) => updateStep(step.id, { verb: event.target.value })}><option>Open</option><option>Place</option><option>Keep</option><option>Focus</option><option>Move</option></select></label>
                              <label><span>Target</span><input value={step.target} onChange={(event) => updateStep(step.id, { target: event.target.value })} /></label>
                              <label><span>Position</span><select value={step.placement} onChange={(event) => updateStep(step.id, { placement: event.target.value })}><option>Left half</option><option>Upper right</option><option>Lower right</option><option>Center</option><option>Next space</option></select></label>
                              <div className="action-step-editor__actions">
                                <button type="button" onClick={() => moveStep(step.id, -1)} disabled={index === 0} aria-label="Move step up">↑</button>
                                <button type="button" onClick={() => moveStep(step.id, 1)} disabled={index === selected.steps.length - 1} aria-label="Move step down">↓</button>
                                <button type="button" onClick={() => deleteStep(step.id)} aria-label="Delete step"><Icon name="trash" /></button>
                              </div>
                            </div>
                          ) : null}
                        </div>
                      );
                    })}
                    {!selected.steps.length ? <div className="action-steps__empty"><strong>No outcome steps yet</strong><span>Add a step or describe the outcome and choose Interpret.</span><button type="button" onClick={addStep}>Add first step</button></div> : null}
                  </div>
                </section>

                <section className="action-section action-behavior">
                  <div className="action-section-heading"><span>Behavior</span><span>Defaults</span></div>
                  <label><span><strong>Reuse open windows</strong><small>Prefer what is already open</small></span><input type="checkbox" checked={reuseWindows} onChange={(event) => setReuseWindows(event.target.checked)} /></label>
                  <label><span><strong>Preserve unsaved work</strong><small>Never close a window with changes</small></span><input type="checkbox" checked={preserveWork} onChange={(event) => setPreserveWork(event.target.checked)} /></label>
                </section>
              </div>
            </section>

            <aside className="action-preview">
              <div className="action-preview__heading"><span>Workspace preview</span><span>Illustrative</span></div>
              <p className="action-preview__caption">Numbers match the outcome steps.</p>
              <WorkspacePreview steps={selected.steps} scene={scene} />
              <RuntimeResult scene={scene} isRestored={isRestored} onRestore={() => setIsRestored(true)} onRetry={runTest} />
            </aside>
          </>
        ) : (
          <section className="action-empty-state">
            <span className="action-empty-state__icon"><Icon name="action" /></span>
            <h2>No actions yet</h2>
            <p>Describe a workspace outcome once, then run it by voice or from a remote control.</p>
            <button className="action-control action-control--primary" type="button" onClick={createAction}><Icon name="plus" /> Create an action</button>
          </section>
        )}
      </div>
    </section>
  );
}

function RuntimeResult({ scene, isRestored, onRestore, onRetry }: { scene: ActionEditorScene; isRestored: boolean; onRestore: () => void; onRetry: () => void }) {
  const content = scene === "tested"
    ? { tone: "good", title: isRestored ? "Previous layout restored" : "Test completed", body: isRestored ? "Every window returned to its original frame." : "Three windows matched. The original arrangement can be restored." }
    : scene === "failed"
      ? { tone: "bad", title: "Test stopped safely", body: "The release page did not open. No workspace changes were kept." }
      : scene === "partial"
        ? { tone: "warn", title: "Ready with fallback", body: "Two exact matches and one compatible terminal fallback." }
        : scene === "unavailable"
          ? { tone: "bad", title: "One step unavailable", body: "GitHub cannot be opened on this Mac. Two other steps are ready." }
          : { tone: "neutral", title: "Ready to test", body: "Uses the windows on this Mac. No changes are made until you run it." };

  return (
    <div className="action-preview__runtime" data-tone={content.tone}>
      <div>
        <span className={content.tone === "good" ? "is-good" : ""}>
          {content.tone === "good" ? <Icon name="check" /> : content.tone === "neutral" ? <i className="action-preview__runtime-dot" /> : <Icon name="alert" />}
        </span>
        <strong>{content.title}</strong>
      </div>
      <p>{content.body}</p>
      {scene === "failed" ? <button type="button" onClick={onRetry}>Retry test</button> : <button type="button" disabled={scene !== "tested" || isRestored} onClick={onRestore}>{isRestored ? "Restored" : "Restore previous layout"}</button>}
    </div>
  );
}
