// Portable ES module: used by both the CLI and Qt's JavaScript engine.
// Return null so each interface can keep its own usage/error presentation.
export function workspaceTarget(value) {
  const directions = { next: "e+1", prev: "e-1", previous: "previous" };
  if (Object.prototype.hasOwnProperty.call(directions, value)) return directions[value];
  return /^[1-9]\d*$/.test(value) && Number(value) <= 2147483647 ? Number(value) : null;
}
