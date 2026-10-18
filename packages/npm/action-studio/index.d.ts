export type ActionPlacement =
  | "left"
  | "right"
  | "upper-left"
  | "upper-right"
  | "lower-left"
  | "lower-right"
  | "center"
  | "maximize"
  | "keep-visible";

export interface ActionOutcomeRule {
  id: string;
  label: string;
  target: string;
  placement: ActionPlacement;
}

export interface ActionDefinition {
  schemaVersion: 1;
  id: string;
  name: string;
  status: "draft" | "saved";
  instruction: string;
  triggers: string[];
  outcomes: ActionOutcomeRule[];
  behavior: {
    reuseOpenWindows: boolean;
    preserveUnsavedWork: boolean;
    ambiguity: "ask" | "skip" | "best-match";
  };
}

export interface ActionStudioCapabilities {
  placements: ActionPlacement[];
  canPlan: boolean;
  canTest: boolean;
  canSave: boolean;
}

export interface ActionStudioStatus {
  tone: "idle" | "working" | "success" | "warning" | "error";
  message: string;
}

export interface ActionDefinitionEventDetail {
  definition: ActionDefinition;
}

export interface ActionInterpretEventDetail {
  instruction: string;
}

export class LatticesActionEditor extends HTMLElement {
  setDefinition(definition: Partial<ActionDefinition>): void;
  getDefinition(): ActionDefinition;
  setCapabilities(capabilities: Partial<ActionStudioCapabilities>): void;
  setStatus(status: ActionStudioStatus): void;
}

export function defineLatticesActionEditor(tagName?: string): void;
export function normalizeDefinition(input?: Partial<ActionDefinition>): ActionDefinition;
export const sampleDefinition: ActionDefinition;
export const defaultCapabilities: ActionStudioCapabilities;

declare global {
  interface HTMLElementTagNameMap {
    "lattices-action-editor": LatticesActionEditor;
  }

  interface HTMLElementEventMap {
    "lattices-action-change": CustomEvent<ActionDefinitionEventDetail>;
    "lattices-action-interpret": CustomEvent<ActionInterpretEventDetail>;
    "lattices-action-test": CustomEvent<ActionDefinitionEventDetail>;
    "lattices-action-save": CustomEvent<ActionDefinitionEventDetail>;
    "lattices-action-voice-request": CustomEvent<Record<string, never>>;
  }
}
