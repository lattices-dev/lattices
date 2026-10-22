/** Keep a documentation page distinct from public AGENTS.md on case-insensitive hosts. */
export function docMarkdownUrl(route) {
  return /\/agents$/i.test(route) ? `${route}/index.md` : `${route}.md`
}
