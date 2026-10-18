"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { EngMarkdown } from "studio/doc";
import {
  ENG_DOC_GROUPS,
  findEntryBySlug,
  findEntryBySourcePath,
  type EngDocEntry,
} from "@/studio/lib/engDocs";
import { StatusPill, statusToColor } from "@/studio/lib/StatusPill";

/** Markdown is read off disk by the API route; the shell stays client-side. */
async function loadDoc(entry: EngDocEntry): Promise<string> {
  const res = await fetch(`/api/studio/eng/${entry.slug}`);
  if (!res.ok) throw new Error(`${res.status} loading ${entry.sourcePath}`);
  return res.text();
}

const REPO_GITHUB_BASE = "https://github.com/arach/lattices/blob/main";

function buildFileHref(path: string, fromSlug?: string): string {
  const cleaned = path.replace(/^\.?\//, "").replace(/[#?].*$/, "");
  for (const candidate of [cleaned, `docs/${cleaned}`]) {
    const entry = findEntryBySourcePath(candidate);
    if (entry) {
      return `/studio/eng/${entry.slug}${fromSlug ? `?from=/studio/eng/${fromSlug}` : ""}`;
    }
  }
  return `${REPO_GITHUB_BASE}/${cleaned}`;
}

interface DocPageProps {
  slug: string;
}

interface DocFrame {
  /** Lead-in paragraph for the page header. */
  dek: string | null;
  /** Body with frontmatter + the leading h1 stripped. */
  bodyWithoutH1: string;
}

function findGroupLabel(slug: string): string | null {
  for (const group of ENG_DOC_GROUPS) {
    if (group.entries.some((entry) => entry.slug === slug)) {
      return group.label;
    }
  }
  return null;
}

function deriveFrame(raw: string, entryBlurb?: string): DocFrame {
  // Strip frontmatter so it never reaches the renderer or the dek.
  let body = raw;
  if (body.startsWith("---")) {
    const end = body.indexOf("\n---", 3);
    if (end !== -1) body = body.slice(end + 4).replace(/^\s*\n/, "");
  }

  // Strip leading h1 — the page header already shows the title.
  const bodyWithoutH1 = body.replace(/^\s*#\s+[^\n]+\n+/, "");

  let dek = entryBlurb?.trim() ?? null;
  if (!dek) {
    // Walk paragraphs that aren't headings, fences, lists, tables, or
    // quotes. Skip very short ones (e.g. a one-line "Status" stub) to
    // find a paragraph that actually carries the doc's thesis.
    const lines = bodyWithoutH1.split("\n");
    const paras: string[] = [];
    let buf: string[] = [];
    let inFence = false;
    const flush = () => {
      if (buf.length) {
        paras.push(buf.join(" ").replace(/\s+/g, " ").trim());
        buf = [];
      }
    };
    for (const line of lines) {
      if (/^```/.test(line)) {
        flush();
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      if (!line.trim()) {
        flush();
        continue;
      }
      if (/^(#{1,6}\s|>|[-*+]\s|\d+\.\s|\|)/.test(line)) {
        flush();
        continue;
      }
      buf.push(line.trim());
    }
    flush();

    const meaty = paras.find((p) => stripInlineMarkdown(p).length >= 80);
    const chosen = meaty ?? paras[0] ?? null;
    if (chosen) {
      const clean = stripInlineMarkdown(chosen);
      dek = clean.length > 240
        ? clean.slice(0, 237).replace(/\s+\S*$/, "") + "…"
        : clean;
    }
  }

  return { dek, bodyWithoutH1 };
}

function stripInlineMarkdown(text: string): string {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]+\)/g, "$1") // images + links
    .replace(/`([^`]+)`/g, "$1") // inline code
    .replace(/\*\*([^*]+)\*\*/g, "$1") // bold
    .replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "$1") // italic *
    .replace(/(?<!_)_([^_]+)_(?!_)/g, "$1") // italic _
    .trim();
}

function sourceGithubHref(path: string): string {
  return `${REPO_GITHUB_BASE}/${path.replace(/^\.?\//, "")}`;
}

type EyebrowPart = { key: string; node: ReactNode };

function Eyebrow({
  entry,
  groupLabel,
}: {
  entry: EngDocEntry;
  groupLabel: string | null;
}) {
  const parts: EyebrowPart[] = [];
  if (entry.proposalId) parts.push({ key: "id", node: entry.proposalId });
  else if (groupLabel) parts.push({ key: "group", node: groupLabel });

  return (
    <div className="eng-page__eyebrow">
      {parts.map((part) => (
        <span key={part.key}>{part.node}</span>
      ))}
      {entry.status ? (
        <>
          {parts.length > 0 ? (
            <span className="eng-page__eyebrow-sep" aria-hidden />
          ) : null}
          <StatusPill status={entry.status} variant="text" />
        </>
      ) : null}
    </div>
  );
}

export function DocStudy({ slug }: DocPageProps) {
  const entry = findEntryBySlug(slug);
  const groupLabel = useMemo(() => findGroupLabel(slug), [slug]);
  const [raw, setRaw] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setRaw(null);
    setError(null);
    if (!entry) {
      setError(`No doc registered for "${slug}".`);
      return;
    }
    let cancelled = false;
    loadDoc(entry)
      .then((text) => {
        if (!cancelled) setRaw(text);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [entry, slug]);

  const frame = useMemo(
    () => (raw && entry ? deriveFrame(raw, entry.blurb) : null),
    [raw, entry],
  );

  if (!entry) {
    return (
      <main className="px-8 py-12">
        <h1 className="font-mono text-xs uppercase tracking-[0.18em] text-studio-ink-faint">
          Not found
        </h1>
        <p className="mt-3 text-sm text-studio-ink">{error ?? "Unknown doc."}</p>
      </main>
    );
  }

  return (
    <main className="eng-page px-6 sm:px-10">
      <header className="eng-page__header">
        <Eyebrow entry={entry} groupLabel={groupLabel} />
        <h1 className="eng-page__title">{entry.title}</h1>
        {frame?.dek ? <p className="eng-page__dek">{frame.dek}</p> : null}
      </header>

      <hr className="eng-page__rule" />

      <div className="eng-page__body">
        {error ? (
          <p className="font-mono text-xs text-[color:var(--status-error-fg)]">
            Failed to load: {error}
          </p>
        ) : !frame ? (
          <p className="font-mono text-xs uppercase tracking-[0.22em] text-studio-ink-faint">
            Loading…
          </p>
        ) : (
          <EngMarkdown
            body={frame.bodyWithoutH1}
            fromSlug={slug}
            buildFileHref={buildFileHref}
          />
        )}
      </div>

      <footer className="eng-page__footer">
        {entry.proposalId ? (
          <div className="eng-page__footer-cell">
            <span className="eng-page__footer-label">Proposal</span>
            <span className="eng-page__footer-value">{entry.proposalId}</span>
          </div>
        ) : null}
        {entry.status ? (
          <div className="eng-page__footer-cell">
            <span className="eng-page__footer-label">Status</span>
            <span
              className="eng-page__footer-value"
              style={{ color: statusToColor(entry.status) }}
            >
              {entry.status}
            </span>
          </div>
        ) : null}
        <div className="eng-page__footer-cell">
          <span className="eng-page__footer-label">Source</span>
          <span className="eng-page__footer-value">
            <a
              href={sourceGithubHref(entry.sourcePath)}
              target="_blank"
              rel="noopener noreferrer"
            >
              {entry.sourcePath}
            </a>
          </span>
        </div>
      </footer>
    </main>
  );
}
