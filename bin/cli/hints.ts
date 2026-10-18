import type { HintPack } from "../../packages/desktop-client/hints.ts";
export { linuxHintPack, loadLinuxHintPack, type Hint, type HintGroup, type HintPack } from "../../packages/desktop-client/hints.ts";

export function printHintPack(pack: HintPack): void {
  console.log(`${pack.title} — hints\n\n${pack.note}\n`);
  for (const group of pack.groups) {
    console.log(`${group.title} (${group.scope})`);
    for (const hint of group.hints) {
      console.log(`  ${hint.shortcut || hint.command}\n    ${hint.title} — ${hint.detail}`);
    }
    console.log();
  }
  console.log("Open in Lattices: lats hints --open");
}
