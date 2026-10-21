import { mapWindows, spacesFor } from "./FlightDeckModel.mjs";

// Workspace coordinates are local UI geometry. They never become host mutations.
export function workspaceSheets(display, windows, query) {
  if (!display || !(display.frame?.w > 0) || !(display.frame?.h > 0)) return [];
  const width = display.frame.w, height = display.frame.h;
  const gap = width * 0.12, header = Math.max(60, width * 0.035);
  return spacesFor(display).map((space, index) => ({
    id: space.id, current: space.id === display.currentSpaceId,
    x: index * (width + gap), y: header, w: width, h: height,
    windows: mapWindows(windows, display, space.id, query || ""),
  }));
}

export function worldBounds(sheets) {
  if (!sheets.length) return { x: 0, y: 0, w: 1, h: 1 };
  return { x: 0, y: 0, w: sheets[sheets.length - 1].x + sheets[sheets.length - 1].w, h: sheets[0].y + sheets[0].h };
}

export function sheetBounds(sheet) {
  return sheet ? { x: sheet.x, y: 0, w: sheet.w, h: sheet.y + sheet.h } : { x: 0, y: 0, w: 1, h: 1 };
}

export function fitCamera(bounds, width, height, padding = 28) {
  const zoom = Math.max(0.00001, Math.min(Math.max(1, width - padding * 2) / Math.max(1, bounds.w), Math.max(1, height - padding * 2) / Math.max(1, bounds.h)));
  return { zoom, x: (width - bounds.w * zoom) / 2 - bounds.x * zoom, y: (height - bounds.h * zoom) / 2 - bounds.y * zoom };
}

export function zoomCamera(camera, factor, x, y, minimum, maximum) {
  const zoom = Math.max(minimum, Math.min(maximum, camera.zoom * factor));
  return { zoom, x: x - (x - camera.x) * zoom / camera.zoom, y: y - (y - camera.y) * zoom / camera.zoom };
}

// Interpolate world coordinates at one screen anchor and zoom on a logarithmic
// scale. A cursor-anchored zoom stays anchored at every animation frame.
export function interpolateCamera(from, to, amount, anchorX, anchorY) {
  const t = Math.max(0, Math.min(1, amount));
  if (t === 0) return from;
  if (t === 1) return to;
  const zoom = Math.exp(Math.log(from.zoom) + (Math.log(to.zoom) - Math.log(from.zoom)) * t);
  const fromX = (anchorX - from.x) / from.zoom, fromY = (anchorY - from.y) / from.zoom;
  const toX = (anchorX - to.x) / to.zoom, toY = (anchorY - to.y) / to.zoom;
  return { zoom, x: anchorX - (fromX + (toX - fromX) * t) * zoom, y: anchorY - (fromY + (toY - fromY) * t) * zoom };
}

export function resizedCamera(camera, oldWidth, oldHeight, width, height) {
  return { zoom: camera.zoom, x: camera.x + (width - oldWidth) / 2, y: camera.y + (height - oldHeight) / 2 };
}

export function reconcileCamera(camera, previous, next, width, selectedSpace) {
  if (previous.map(s => s.id).join(",") === next.map(s => s.id).join(",")) return camera;
  const surviving = previous.filter(old => next.some(sheet => sheet.id === old.id));
  if (!surviving.length) return camera;
  const center = (width / 2 - camera.x) / camera.zoom;
  const anchor = surviving.find(s => center >= s.x && center <= s.x + s.w) ||
    surviving.find(s => s.id === selectedSpace) ||
    surviving.reduce((nearest, s) => Math.abs(s.x + s.w / 2 - center) < Math.abs(nearest.x + nearest.w / 2 - center) ? s : nearest);
  const replacement = next.find(s => s.id === anchor.id);
  return { zoom: camera.zoom, x: camera.x - (replacement.x - anchor.x) * camera.zoom, y: camera.y - (replacement.y - anchor.y) * camera.zoom };
}
