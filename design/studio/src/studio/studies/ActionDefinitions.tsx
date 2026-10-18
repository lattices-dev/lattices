"use client";

import { useState } from "react";
import type { LatticesPage } from "@/studio/studioRegistry";
import {
  ActionDefinitionEditor,
  type ActionEditorScene,
  type ActionEditorTone,
} from "@/studio/studies/action-definitions/ActionDefinitionEditor";

const scenes: { id: ActionEditorScene; label: string; note: string }[] = [
  { id: "draft", label: "Definition", note: "Edit the action" },
  { id: "clarify", label: "Clarification", note: "Resolve a detail" },
  { id: "ready", label: "Ready", note: "Review before testing" },
  { id: "partial", label: "Limited", note: "Accept a fallback" },
  { id: "unavailable", label: "Unavailable", note: "Replace a blocked step" },
  { id: "failed", label: "Failed", note: "Recover safely" },
  { id: "tested", label: "Passed", note: "Verify and restore" },
  { id: "empty", label: "Empty", note: "Create the first action" },
];

export function ActionDefinitionsStudy({ page }: { page: LatticesPage }) {
  const [scene, setScene] = useState<ActionEditorScene>("draft");
  const [tone, setTone] = useState<ActionEditorTone>("lattices");

  return (
    <main className="action-study">
      <header className="action-study__header">
        <div>
          <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">
            {page.bucket} / {page.surface}
          </div>
          <h1>{page.label}</h1>
          <p>{page.blurb}</p>
        </div>
        <div className="action-study__skin" aria-label="Host skin">
          <span>Host</span>
          <div>
            <button type="button" aria-pressed={tone === "lattices"} onClick={() => setTone("lattices")}>Lattices</button>
            <button type="button" aria-pressed={tone === "talkie"} onClick={() => setTone("talkie")}>Talkie</button>
          </div>
        </div>
      </header>

      <nav className="action-study__scenes" aria-label="Study states">
        {scenes.map((item) => (
          <button key={item.id} type="button" aria-current={scene === item.id ? "step" : undefined} onClick={() => setScene(item.id)}>
            <strong>{item.label}</strong><span>{item.note}</span>
          </button>
        ))}
      </nav>

      <div className="action-study__frame">
        <ActionDefinitionEditor tone={tone} scene={scene} onSceneChange={setScene} />
      </div>

      <footer className="action-study__footer">
        <p><strong>Study boundary</strong> Interface states use local illustrative data. The daemon, persistence, and macOS WebView bridge remain outside this study.</p>
        <span>Reusable component · responsive · host-themed</span>
      </footer>
    </main>
  );
}
