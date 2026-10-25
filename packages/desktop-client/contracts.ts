export type Rpc = (method: string, params?: Record<string, unknown> | null, timeout?: number) => Promise<unknown>;
export interface Rect { x: number; y: number; w: number; h: number }

export interface Window {
  wid: number;
  address: string;
  app: string;
  pid: number;
  title: string;
  frame: Rect;
  spaceIds: number[];
  displayIndex: number;
  isOnScreen: boolean;
  isFloating: boolean;
  isFullscreen: boolean;
  isFocused: boolean;
  latticesSession?: string;
}

/** The physical panel behind a display, by EDID. `key` names it across every host it is cabled to. */
export interface Monitor {
  make?: string;
  model: string;
  serial: string;
  key: string;
  /** Physical image size in millimetres; omitted when the panel doesn't report one. */
  widthMm?: number;
  heightMm?: number;
}

export interface Display {
  displayIndex: number;
  displayId: string;
  name: string;
  frame: Rect;
  visibleFrame: Rect;
  scale: number;
  /** A headless output: no panel behind it, only captures and remote views see it. */
  virtual: boolean;
  currentSpaceId: number;
  spaces: { id: number; index: number; name: string; display: number; isCurrent: boolean; windowCount: number }[];
  /** Omitted on headless outputs and panels without a serial. */
  monitor?: Monitor;
}
