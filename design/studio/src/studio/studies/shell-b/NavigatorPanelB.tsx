"use client";

import { useState } from "react";
import { BWindow } from "./_b";
import { CommandBar, firstResult, QUERIES, ResultKeys, ResultList, type BQuery } from "./CommandBar";
import { HomeActions } from "./HomePanelB";

/** Home, with a sentence typed. Nothing is dimmed and nothing floats. */
export function NavigatorPanelB() {
  const query = QUERIES.tile;
  const [active, setActive] = useState(firstResult(query));

  return (
    <BWindow tab="home" actions={<HomeActions />}>
      <CommandBar query={query} />
      <ResultList query={query} active={active} onActive={setActive} />
      <ResultKeys query={query} />
    </BWindow>
  );
}

/** The bar and its results at one query, standing alone — for the grammar comparison. */
export function BarStrip({ query }: { query: BQuery }) {
  return (
    <div className="bs bs--strip">
      <CommandBar query={query} />
      <ResultList query={query} active={firstResult(query)} />
      <ResultKeys query={query} />
    </div>
  );
}
