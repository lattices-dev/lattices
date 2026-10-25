import { expect, test } from "bun:test";
import { verifyVirtualProcessGroup, type VirtualProcessGroupMember } from "../src/virtual-process-groups.ts";

const member = (owned: boolean): VirtualProcessGroupMember => ({ pid: 102, group: 101, startTime: "300", owned });

test("a bus process that exits after its environment disappears is not an ownership failure", async () => {
  let observations = 0;
  await expect(verifyVirtualProcessGroup(101, () => {
    observations++;
    return observations <= 2 ? [member(false)] : [];
  }, async () => {})).resolves.toBe(false);
  expect(observations).toBe(3);
});

test("a persistently live unowned process group is refused", async () => {
  let observations = 0;
  let elapsed = 0;
  await expect(verifyVirtualProcessGroup(101, () => {
    observations++;
    return [member(false)];
  }, async milliseconds => { elapsed += milliseconds; }))
    .rejects.toThrow("Virtual process group identity could not be verified: 101 (live members: 102:300)");
  expect(observations).toBe(11);
  expect(elapsed).toBe(250);
});

test("an owned live group is authorized and an empty group needs no signal", async () => {
  expect(await verifyVirtualProcessGroup(101, () => [member(true)])).toBe(true);
  expect(await verifyVirtualProcessGroup(101, () => [])).toBe(false);
});

test("an unrelated group's ownership cannot authorize this group", async () => {
  const members = [member(false), { ...member(true), pid: 202, group: 201 }];
  await expect(verifyVirtualProcessGroup(101, () => members, async () => {}))
    .rejects.toThrow("Virtual process group identity could not be verified: 101");
});

test("each group starts with a fresh observation after another group waited", async () => {
  const first = { ...member(false), group: 100 };
  let members = [first, member(true)];
  const observe = () => members;
  expect(await verifyVirtualProcessGroup(100, observe, async () => {
    members = [{ ...member(false), startTime: "301" }];
  })).toBe(false);
  await expect(verifyVirtualProcessGroup(101, observe, async () => {}))
    .rejects.toThrow("live members: 102:301");
});
