"use client";

import { createElement } from "react";
import { LayoutGrid, Compass } from "lucide-react";
import { StudioHudsonApp } from "studio/app-shell";
import { NextRouterProvider } from "studio/router/next";
import { renderStudioPage } from "@/studio/StudioPages";
import {
  BUCKETS,
  pages,
  HOME_HREF,
  STATUS_COLORS,
  registry,
  statusPalette,
} from "@/studio/studioRegistry";

/**
 * Some studies own a second path segment for their exhibits
 * (`/studio/studies/shell/home`). The registry only knows the parent href, so
 * normalise here: the nav rail lights the parent, and StudioPages recovers the
 * exhibit from the same pathname.
 */
function resolveStudioPath(pathname: string | null, homeHref: string): string {
  if (!pathname || pathname === `${homeHref}/`) return homeHref;
  const path = pathname.length > 1 ? pathname.replace(/\/$/, "") : pathname;
  if (pages.some((page) => page.href === path)) return path;
  // Longest match wins, and the home href is skipped — every path starts with
  // it, so it would otherwise swallow every exhibit route.
  const parent = pages
    .filter((page) => page.href !== homeHref && path.startsWith(`${page.href}/`))
    .sort((a, b) => b.href.length - a.href.length)[0];
  return parent ? parent.href : path;
}

export function StudioApp() {
  return (
    <StudioHudsonApp
      app={{
        id: "lattices-studio",
        name: "Lattices Studio",
        description: "Design studio for the Lattices macOS workspace manager.",
        icon: createElement(LayoutGrid, { size: 14 }),
        leftPanel: {
          title: "Lattices",
          icon: createElement(Compass, { size: 12 }),
        },
      }}
      registry={registry}
      buckets={BUCKETS}
      statusColors={STATUS_COLORS}
      renderStatusPill={(status) => statusPalette.StatusPill({ status })}
      renderPage={renderStudioPage}
      homeHref={HOME_HREF}
      resolvePath={resolveStudioPath}
      routerProvider={NextRouterProvider}
      theme={{
        storageKey: "studio.app.theme",
        defaultTheme: "dark",
        defaultTemplate: "hudson",
      }}
    />
  );
}
