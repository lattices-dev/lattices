"use client";

import type { ReactNode } from "react";
import { BBtn, BSeg, BToolbar } from "./_b";
import { HomeActions } from "./HomePanelB";

export const NAV_NOTES = {
  sidebar: [
    "A 198px rail is **18% of an 1100px window** spent on six words you read once.",
    "Labels on every row make the rail the loudest thing on screen; the page it frames is quieter than its own navigation.",
    "A title bar that repeats the selected rail item says **where you are twice**.",
    "The status strip holds still by carrying **the same three facts on every page**, whether or not the page has anything to do with them.",
  ],
  toolbar: [
    "Five tabs sit in the **unified toolbar** beside the traffic lights — the height the window already pays for.",
    "Page actions live in the same band, at the right, so **every page has one row of chrome**, not two.",
    "Below 640px the tabs drop to glyphs with tooltips — the old icon rail, kept as the **narrow fallback** rather than the default.",
    "Nothing sits under the content. Each fact from the status strip moved **next to what it qualifies**, or became a dot.",
  ],
};

/** Where each status-bar item went. */
export const STATUS_MOVES: [string, string][] = [
  ["2 running · 4 projects", "The count beside Sessions on Home; a green dot on each running row."],
  ["38 windows tracked · 2 monitors · 4 spaces", "The Desktop page, which draws them."],
  ["OCR armed · 14 reviewed · 40s review", "\"Scanned 40s ago\" beside the filter it qualifies."],
  ["n selected", "The detail bar shows the selected window; there is no count to keep."],
  ["Logs · 2 err", "A count on the Log tab, only while errors > 0."],
  ["Daemon :9399", "A 6px dot beside Settings: neutral connected, amber reconnecting, red down."],
  ["Page label · preset · mode", "The selected tab."],
];

function Strip({ cap, width, children }: { cap: string; width: number; children: ReactNode }) {
  return (
    <div className="bs-strip" style={{ width }}>
      <p className="bs-strip__cap">{cap}</p>
      <div className="bs-strip__bar">{children}</div>
    </div>
  );
}

export function NavigationPanelB() {
  return (
    <div className="bs bs--stack">
      <Strip cap="1100 · Home" width={1052}>
        <BToolbar tab="home" actions={<HomeActions />} />
      </Strip>

      <Strip cap="1100 · Desktop — same tabs, this page's actions" width={1052}>
        <BToolbar
          tab="desktop"
          actions={
            <>
              <BBtn icon="scan">Scan</BBtn>
              <BSeg
                value="map"
                options={[
                  { id: "map", icon: "display", label: "Map" },
                  { id: "list", icon: "list", label: "List" },
                ]}
              />
            </>
          }
        />
      </Strip>

      <Strip cap="760 · page actions fold into one control" width={760}>
        <BToolbar tab="desktop" folded />
      </Strip>

      <Strip cap="520 · tabs become glyphs with tooltips" width={520}>
        <BToolbar tab="desktop" folded compact />
      </Strip>
    </div>
  );
}
