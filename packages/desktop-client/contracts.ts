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
}
