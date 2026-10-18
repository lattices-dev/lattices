import { describe, test, expect } from 'bun:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { ActionMark } from './ActionMark';

const render = (props = {}) => renderToStaticMarkup(createElement(ActionMark, props));
describe('ActionMark', () => {
  test('keeps masks and patterns unique across instances', () => {
    const html = renderToStaticMarkup(createElement('div', null,
      createElement(ActionMark), createElement(ActionMark, { theme: 'dark' })));
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    expect(new Set(ids).size).toBe(ids.length);
    for (const [, ref] of html.matchAll(/url\(#([^)]+)\)/g)) expect(ids).toContain(ref);
  });
  test('clean mark removes all construction layers and draws the A in the ink, the cursor in the accent', () => {
    const html = render({ guides: false, background: false });
    expect(html).not.toContain('<text');
    expect(html).not.toContain('<rect');
    expect(html).not.toContain('stroke-dasharray');
    expect(html).toContain('mask=');
    const fills = (markup: string) => [...markup.matchAll(/fill="(#[0-9a-f]{6})"/g)].map(m => m[1]);
    expect(fills(html)).toEqual(['#101518', '#ef6a47']);
    expect(fills(render({ guides: false, background: false, accent: false }))).toEqual(['#101518', '#101518']);
  });
  test('supports dark palette, paper padding, and independent title block', () => {
    const html = render({ theme: 'dark', padding: 40, guides: false, titleBlock: true, year: 2027 });
    expect(html).toContain('viewBox="-40 -40 800 720"');
    expect(html).toContain('fill="#19282a"');
    expect(html).toContain('DESIGNED 2027');
    expect(html).not.toContain('LEFT SLOPE');
  });
  test('supports accessible names and decorative usage', () => {
    expect(render({ label: 'Action construction' })).toContain('Action construction</title>');
    const html = render({ decorative: true });
    expect(html).toContain('aria-hidden="true"');
    expect(html).not.toContain('<title');
  });
});
