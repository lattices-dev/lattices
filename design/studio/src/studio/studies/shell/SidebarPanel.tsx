"use client";

import { AppWindow, Icon, Mark, NAV_GROUPS, type IconName } from "./_shell";

/** The shipping rail: icon-only, flat, and the brand mark doubles as the toggle. */
const OLD_RAIL: IconName[] = ["home", "assistant", "studio", "windows", "runs", "activity"];

export const SIDEBAR_NOTES = {
  old: [
    "Six glyphs, no labels, until you discover that the **logo is a disclosure control**.",
    "Assistant, Studio, Windows, Runs, and Activity sit as **flat peers** — nothing says which are places and which are logs.",
    "**Settings and Docs** leave the rail with nothing selected, so the app looks like it's nowhere.",
    "The status strip carries **five to seven live values** that change per page, so its shape never stabilizes.",
  ],
  now: [
    "**Three groups** answer \"what kind of thing is this\": places you work, agent surfaces, system state.",
    "Labels are always on. Collapsing to icons stays available, but as **a preference, not the default**.",
    "Counts ride the items that have a live number — **windows and runs** — so the status bar doesn't have to.",
    "The footer holds the two **ambient** things: daemon reachability, and Settings, which now keeps its own selected state.",
  ],
};

export function SidebarPanel() {
  return (
    <AppWindow title="Navigation">
      <div className="as-compare">
        <div>
          <p className="as-side__label" style={{ padding: "0 0 10px" }}>
            Icon rail · shipping
          </p>
          <div className="as-cmp__stage">
            <div className="as-minirail as-minirail--old">
              <div className="as-oldic" style={{ marginBottom: 10 }}>
                <Mark />
              </div>
              {OLD_RAIL.map((icon, i) => (
                <div key={icon} className={`as-oldic${i === 0 ? " as-oldic--on" : ""}`}>
                  <Icon name={icon} />
                </div>
              ))}
              <div className="as-oldic" style={{ marginTop: "auto" }}>
                <Icon name="gear" />
              </div>
            </div>
          </div>
        </div>

        <div>
          <p className="as-side__label" style={{ padding: "0 0 10px", color: "var(--app-accent)" }}>
            Labeled sidebar · proposed
          </p>
          <div className="as-cmp__stage">
            <div className="as-minirail as-minirail--new">
              <div className="as-rail__head" style={{ padding: "2px 13px 12px" }}>
                <Mark />
                <span className="as-rail__wordmark">Lattices</span>
              </div>
              {NAV_GROUPS.map((group) => (
                <div className="as-group" key={group.label}>
                  <p className="as-group__label">{group.label}</p>
                  {group.items.map((item) => (
                    <button
                      key={item.id}
                      type="button"
                      className="as-nav"
                      aria-current={item.id === "home" ? "page" : undefined}
                    >
                      <Icon name={item.icon} />
                      {item.label}
                      {item.count !== undefined ? (
                        <span className="as-nav__count">{item.count}</span>
                      ) : null}
                    </button>
                  ))}
                </div>
              ))}
              <div className="as-rail__foot">
                <div className="as-host">
                  <span className="as-host__pulse" />
                  <span className="as-host__name">Daemon</span>
                  <span className="as-host__port">:9399</span>
                </div>
                <button type="button" className="as-nav">
                  <Icon name="gear" />
                  Settings
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </AppWindow>
  );
}
