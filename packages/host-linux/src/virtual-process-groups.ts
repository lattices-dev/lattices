export interface VirtualProcessGroupMember {
  pid: number;
  group: number;
  startTime: string;
  owned: boolean;
}

/** Return false for an exited group; never authorize a live unowned group. */
export async function verifyVirtualProcessGroup(
  group: number,
  observe: () => VirtualProcessGroupMember[],
  pause: (milliseconds: number) => Promise<void> = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
): Promise<boolean> {
  let members = observe();
  for (let attempt = 0; ; attempt++) {
    const live = members.filter(member => member.group === group);
    if (!live.length) return false;
    if (live.some(member => member.owned)) return true;
    if (attempt === 10) {
      throw new Error("Virtual process group identity could not be verified: " + group + " (live members: " + live.map(member => `${member.pid}:${member.startTime}`).join(", ") + ")");
    }
    // dbus-run-session exits after terminating its bus, without waiting for it.
    // Linux can clear a dying process's environ before stat reports a zombie.
    // Re-observe that transition; elapsed time alone never authorizes a signal.
    await pause(25);
    members = observe();
  }
}
