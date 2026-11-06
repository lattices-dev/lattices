import type { ReactNode } from "react";
import { ActionMark } from "./ActionMark";
import { CuaMark, OpenAIMark } from "./BackendMarks";
import { actionMarkBox } from "../lib/marks";

type Tier = "semantic" | "attention";

type Backend = {
  id: string;
  name: string;
  short: string;
  engine: string;
  requires: string;
  mark: ReactNode;
  tiers: Record<string, Tier>;
};

const markStyle = { width: 28, height: 28 };

const backends: Backend[] = [
  {
    id: "action-cua",
    short: "Action",
    name: "Action",
    engine: "Action.app's native host",
    requires: "Action.app",
    mark: (
      <ActionMark
        palette={{ ink: "currentColor" }}
        guides={false}
        background={false}
        viewBox={actionMarkBox.join(" ")}
        decorative
        style={markStyle}
      />
    ),
    tiers: { press: "semantic", setValue: "semantic", input: "attention" },
  },
  {
    id: "codex-cua",
    short: "Codex",
    name: "Codex Computer Use",
    engine: "OpenAI",
    requires: "ChatGPT desktop app, Computer Use plugin",
    mark: <OpenAIMark style={markStyle} />,
    tiers: { press: "semantic", setValue: "attention", input: "attention" },
  },
  {
    id: "trycua-cua",
    short: "Cua",
    name: "Cua Driver",
    engine: "trycua",
    requires: "CuaDriver.app and cua-driver",
    mark: <CuaMark style={markStyle} />,
    tiers: { press: "semantic", setValue: "semantic", input: "attention" },
  },
];

const rows: Array<{ kind: string; label: string }> = [
  { kind: "press", label: "press" },
  { kind: "setValue", label: "set value" },
  { kind: "input", label: "type, key, click, scroll" },
];

export function ActionBackends() {
  return (
    <section id="backends" className="action-backends" aria-labelledby="action-backends-title">
      <div className="action-section-heading">
        <p className="action-kicker">Computer use</p>
        <h2 id="action-backends-title">Three engines. One contract.</h2>
        <p>
          Every command names its backend. Targets, observe and act mean the same thing on each, and nothing falls back to another engine.
        </p>
      </div>

      <ul className="action-backend-cards">
        {backends.map((backend) => (
          <li key={backend.id}>
            <span className="action-backend-mark">{backend.mark}</span>
            <code className="action-backend-id">{backend.id}</code>
            <h3>{backend.name}</h3>
            <p className="action-backend-engine">{backend.engine}</p>
            <dl>
              <dt>Needs</dt>
              <dd>{backend.requires}</dd>
            </dl>
            <code className="action-backend-setup">action setup {backend.id}</code>
          </li>
        ))}
      </ul>

      <div className="action-tier-gate">
        <div className="action-tier-copy">
          <h3>The tier gate</h3>
          <p>
            <strong>Semantic</strong> acts go through Accessibility. Your pointer and focus stay where they are.
          </p>
          <p>
            <strong>Attention</strong> acts move focus or the pointer. They are refused until you pass <code>--allow attention</code>, and nothing is sent.
          </p>
        </div>
        <table className="action-tier-table">
          <thead>
            <tr>
              <th scope="col"><span className="sr-only">Action</span></th>
              {backends.map((backend) => <th key={backend.id} scope="col" title={backend.id}>{backend.short}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.kind}>
                <th scope="row">{row.label}</th>
                {backends.map((backend) => {
                  const tier = backend.tiers[row.kind];
                  return <td key={backend.id} data-tier={tier}>{tier}</td>;
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
