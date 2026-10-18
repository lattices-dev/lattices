import { useId, type SVGProps } from 'react';
import { actionCursor, latticesAccent, latticesPalette } from '../lib/marks';

export interface ActionPalette {
  paper: string;
  ink: string;
  /** Defaults to the family coral; `accent={false}` draws it in the ink. */
  cursor: string;
  guide: string;
  grid: string;
}

export interface ActionMarkProps extends Omit<SVGProps<SVGSVGElement>, 'children' | 'name'> {
  theme?: 'light' | 'dark';
  /** The cursor's colour, or `false` for one ink. Defaults to Action's coral. */
  accent?: string | false;
  /** Show the architectural construction layer. Defaults to true. */
  guides?: boolean;
  /** These layers default to the guides setting, but can be controlled separately. */
  grid?: boolean;
  annotations?: boolean;
  titleBlock?: boolean;
  background?: boolean;
  /** Extra SVG units of paper around the approved 720 × 640 drawing. */
  padding?: number;
  palette?: Partial<ActionPalette>;
  label?: string;
  decorative?: boolean;
  figure?: string;
  name?: string;
  organization?: string;
  year?: number;
  revision?: string;
}

/**
 * Action construction with equal perpendicular edge widths. The A fills a
 * square, and the cursor lies on the square's diagonal with its tip on the
 * counter's edge and its tail touching the square, so the glyph is the square.
 * Geometry is fixed; presentation is configurable.
 */
export function ActionMark({
  theme = 'light', accent, guides = true, grid = guides, annotations = guides,
  titleBlock = guides, background = true, padding = 0, palette,
  label = 'Action logo', decorative = false,
  figure = 'FIG. A', name = 'ACTION', organization = 'LATTICES',
  year = 2026, revision = 'STUDY 03', style, ...svgProps
}: ActionMarkProps) {
  const id = useId();
  const gridId = `${id}-grid`;
  const gapId = `${id}-gap`;
  const titleId = `${id}-title`;
  const inset = Number.isFinite(padding) ? Math.max(0, padding) : 0;
  const ink = palette?.ink ?? latticesPalette[theme].ink;
  const colors: ActionPalette = {
    paper: theme === 'dark' ? '#19282a' : '#f4efe6',
    ink, cursor: accent === false ? ink : accent ?? latticesAccent[theme],
    guide: theme === 'dark' ? '#819d96' : '#71908d',
    grid: '#367b7c', ...palette,
  };
  return (
    <svg xmlns="http://www.w3.org/2000/svg"
      viewBox={`${-inset} ${-inset} ${720 + inset * 2} ${640 + inset * 2}`}
      style={{ display: 'block', width: '100%', height: 'auto', ...style }}
      {...svgProps}
      role={decorative ? undefined : 'img'}
      aria-hidden={decorative || undefined}
      aria-labelledby={decorative ? undefined : titleId}
    >
      {!decorative && <title id={titleId}>{label}</title>}
      {background && <rect x={-inset} y={-inset} width={720 + inset * 2} height={640 + inset * 2} fill={colors.paper} />}
      <defs>
        <pattern id={gridId} width="20" height="20" patternUnits="userSpaceOnUse">
          <path d="M20 0H0V20" fill="none" stroke={colors.grid} strokeOpacity=".14" strokeWidth=".5" />
        </pattern>
        <mask id={gapId} maskUnits="userSpaceOnUse" x="0" y="0" width="720" height="640">
          <path d="M0 0H720V640H0Z" fill="white" />
          <path d="M -23.662015831524982 0 L 500 -244.18760826712423 L 500 244.18760826712423 Z" transform="translate(348.61256823541 348.61256823541) rotate(45)" fill="black" />
        </mask>
      </defs>
      {grid && (
      <path fill={`url(#${gridId})`} d="M0 0H720V640H0Z" />
      )}
      <path d="M265 70H335L530 530H70Z M300 233.93676624418646L215.2785567844705 433.7924784449227H384.72144321552946Z" fill={colors.ink} fillRule="evenodd" mask={`url(#${gapId})`} />
      <path d={actionCursor.d} transform="translate(348.61256823541 348.61256823541) rotate(45)" fill={colors.cursor} />
      {guides && (
      <g fill="none" stroke={colors.guide} strokeWidth=".55" strokeOpacity=".6" strokeDasharray="3 4">
        <path d="M18 530H670 M18 70H470 M70 18V550 M530 160V550 M300 18V555 M286.19565217391306 20L61.52173913043484 550 M313.80434782608694 20L538.4782608695651 550 M318.625368299166 190L208.4079769948182 450 M281.374631700834 190L391.5920230051818 450 M190 433.7924784449227H410 M50 50L550 550" />
        <path d="M-35 -16.32076803542495L235 109.58229966642467 M-35 16.32076803542495L235 -109.58229966642467" transform="translate(348.61256823541 348.61256823541) rotate(45)" />
        <circle cx="348.61256823541" cy="348.61256823541" r="7" />
        <path d="M335.61256823541 348.61256823541H361.61256823541 M348.61256823541 335.61256823541V361.61256823541" />
        <circle cx="530" cy="416.43943484058093" r="5" />
        <circle cx="416.43943484058093" cy="530" r="5" />
      </g>
      )}
      {annotations && (
      <g fill="none" stroke={colors.guide} strokeWidth=".55" strokeOpacity=".7">
        <path d="M50 270H98L135 286 M555 240H515L448 270 M300 555V540" strokeDasharray="3 4" />
        <circle cx="38" cy="270" r="12" />
        <circle cx="567" cy="240" r="12" />
        <circle cx="300" cy="567" r="12" />
      </g>
      )}
      {annotations && (
      <g fill={colors.ink} fontFamily="monospace" fontSize="11" textAnchor="middle">
        <text x="38" y="274">A</text>
        <text x="567" y="244">B</text>
        <text x="300" y="571">C</text>
      </g>
      )}
      {annotations && (
      <g fill={colors.ink} fontFamily="monospace" fontSize="9">
        <text x="40" y="612">A / LEFT SLOPE</text>
        <text x="210" y="612">B / RIGHT SLOPE</text>
        <text x="390" y="612">C / BASE</text>
        <text x="40" y="630">A = B = C : 96.21 UNITS, MEASURED PERPENDICULAR TO EACH EDGE</text>
      </g>
      )}
      {titleBlock && (
      <g fontFamily="monospace" fill={colors.ink}>
        <path d="M485 38H680 M485 70H680 M485 145H680" stroke={colors.guide} strokeWidth=".5" opacity=".55" />
        <text x="485" y="56" fontSize="10" letterSpacing="1.2">{figure} / {name}</text>
        <g fontSize="8" opacity=".7">
          <text x="485" y="86">{organization} / LOGO CONSTRUCTION</text>
          <text x="485" y="101">DESIGNED {year} · {revision}</text>
          <text x="485" y="116">SQUARE 460 U / SLOPES 67°</text>
          <text x="485" y="131">EDGE WIDTH 96.21 U / GAP 10 U</text>
        </g>
      </g>
      )}
      {annotations && (
      <g fill={colors.ink} fontFamily="monospace" fontSize="9">
        <text x="36" y="585">EQUAL EDGE WIDTH / 67° SLOPES / 10 UNIT GAP</text>
        <text x="420" y="572">TIP ON DIAGONAL AND COUNTER EDGE</text>
        <text x="420" y="585">TAIL TOUCHES THE SQUARE</text>
      </g>
      )}
    </svg>
  );
}
