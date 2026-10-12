import { describe, expect, test } from "bun:test";
import dbus from "dbus-next";
import { unitArgument } from "../scripts/install-tray.ts";
import { iconPixmap } from "../src/tray/item.ts";
import { menuProperties, TrayMenu } from "../src/tray/menu.ts";

describe("tray menu contract", () => {
  test("dbusmenu layout has typed variants, stable IDs and disabled status", async () => {
    const clicked: number[] = [];
    let refreshes = 0;
    const menu = new TrayMenu(async () => { refreshes++; }, (id) => clicked.push(id));
    menu.update([
      { id: 1, label: "Bring Cursor Home" },
      { id: 3, label: "Host: On · Paired", enabled: false }, { id: 5, label: "Quit" },
    ]);
    const [, layout] = await menu.GetLayout(0, -1, []);
    const children = (layout as [number, unknown, dbus.Variant[]])[2];
    expect(children.map((c) => c.value[0])).toEqual([1, 3, 5]);
    expect(children[1].signature).toBe("(ia{sv}av)");
    expect(children[1].value[1].enabled.value).toBe(false);
    expect(refreshes).toBe(1);
    menu.Event(1, "clicked", new dbus.Variant("i", 0), 0);
    menu.Event(3, "clicked", new dbus.Variant("i", 0), 0);
    expect(clicked).toEqual([1]);
    const revision = menu.revision;
    menu.update(menu.items.slice());
    expect(menu.revision).toBe(revision); // Avoid LayoutUpdated/GetLayout loops.
  });
  test("returns only requested properties", () => {
    const menu = new TrayMenu(async () => {}, () => {});
    menu.update([{ id: 4, label: "Start Host", enabled: true }]);
    expect(menu.GetGroupProperties([4], ["enabled"])[0][1]).toEqual({ enabled: new dbus.Variant("b", true) });
    expect(menuProperties({ id: 6, separator: true })).toEqual({ type: new dbus.Variant("s", "separator") });
    expect(() => menu.GetProperty(9, "label")).toThrow();
  });
});

test("tray icon is monochrome", () => {
  const [[width, height, pixels]] = iconPixmap();
  expect(pixels.length).toBe(width * height * 4);
  const colours = new Set<string>();
  for (let i = 0; i < pixels.length; i += 4) if (pixels[i]) colours.add(pixels.subarray(i + 1, i + 4).toString("hex"));
  expect([...colours]).toEqual(["e8e8e8"]);
});

test("service paths are literal systemd arguments, including spaces and specifiers", () => {
  expect(unitArgument('/tmp/a b/%$"\\')).toBe('"/tmp/a b/%%$$\\"\\\\"');
  expect(() => unitArgument("/tmp/bad\npath")).toThrow();
});
