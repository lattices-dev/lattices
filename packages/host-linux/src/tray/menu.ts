import dbus from "dbus-next";

const { Interface } = dbus.interface;
type Properties = Record<string, dbus.Variant>;
export interface MenuItem { id: number; label?: string; enabled?: boolean; separator?: boolean; checked?: boolean }

export function menuProperties(item: MenuItem): Properties {
  if (item.separator) return { type: new dbus.Variant("s", "separator") };
  const properties: Properties = {
    label: new dbus.Variant("s", item.label ?? ""),
    enabled: new dbus.Variant("b", item.enabled ?? true),
    visible: new dbus.Variant("b", true),
  };
  if (item.checked !== undefined) {
    properties["toggle-type"] = new dbus.Variant("s", "checkmark");
    properties["toggle-state"] = new dbus.Variant("i", item.checked ? 1 : 0);
  }
  return properties;
}

/** Flat dbusmenu; Quickshell owns all popup rendering and styling. */
export class TrayMenu extends Interface {
  readonly Version = 4;
  readonly TextDirection = "ltr";
  readonly Status = "normal";
  readonly IconThemePath: string[] = [];
  revision = 1;
  items: MenuItem[] = [];

  constructor(private refresh: () => Promise<void>, private activate: (id: number) => void) {
    super("com.canonical.dbusmenu");
  }

  update(items: MenuItem[]) {
    if (JSON.stringify(this.items) === JSON.stringify(items)) return;
    this.items = items;
    this.revision++;
    this.LayoutUpdated(this.revision, 0);
  }

  private properties(id: number, names: string[] = []): Properties {
    const item = this.items.find((i) => i.id === id);
    const properties = id === 0 ? { "children-display": new dbus.Variant("s", "submenu") } : item ? menuProperties(item) : {};
    return names.length ? Object.fromEntries(Object.entries(properties).filter(([name]) => names.includes(name))) : properties;
  }

  async GetLayout(parent: number, depth: number, names: string[]) {
    // Quickshell also reads layouts directly on opening; refresh there as well
    // as AboutToShow. Signals are emitted only when values actually change.
    if (parent === 0) await this.refresh();
    const children = parent === 0 && depth !== 0 ? this.items.map((item) =>
      new dbus.Variant("(ia{sv}av)", [item.id, this.properties(item.id, names), []])) : [];
    return [this.revision, [parent, this.properties(parent, names), children]];
  }

  GetGroupProperties(ids: number[], names: string[]) {
    return (ids.length ? ids : this.items.map((i) => i.id)).map((id) => [id, this.properties(id, names)]);
  }

  GetProperty(id: number, name: string) {
    const value = this.properties(id)[name];
    if (!value) throw new dbus.DBusError("com.canonical.dbusmenu.Error.InvalidProperty", name);
    return value;
  }

  Event(id: number, event: string, _data: dbus.Variant, _timestamp: number) {
    if (event === "clicked" && this.items.some((i) => i.id === id && i.enabled !== false && !i.separator)) this.activate(id);
    else if (event === "opened") void this.refresh().catch(console.error);
  }

  EventGroup(events: [number, string, dbus.Variant, number][]) {
    const errors: number[] = [];
    for (const [id, event, data, timestamp] of events) {
      if (!this.items.some((i) => i.id === id)) errors.push(id);
      else this.Event(id, event, data, timestamp);
    }
    return errors;
  }

  async AboutToShow(_id: number) {
    const revision = this.revision;
    await this.refresh();
    return revision !== this.revision;
  }

  async AboutToShowGroup(ids: number[]) {
    const revision = this.revision;
    await this.refresh();
    return [revision !== this.revision ? ids : [], []];
  }

  LayoutUpdated(revision: number, parent: number) { return [revision, parent]; }
  ItemsPropertiesUpdated(updated: unknown[], removed: unknown[]) { return [updated, removed]; }
}

TrayMenu.configureMembers({
  properties: {
    Version: { signature: "u", access: "read" }, TextDirection: { signature: "s", access: "read" },
    Status: { signature: "s", access: "read" }, IconThemePath: { signature: "as", access: "read" },
  },
  methods: {
    GetLayout: { inSignature: "iias", outSignature: "u(ia{sv}av)" },
    GetGroupProperties: { inSignature: "aias", outSignature: "a(ia{sv})" },
    GetProperty: { inSignature: "is", outSignature: "v" },
    Event: { inSignature: "isvu" }, EventGroup: { inSignature: "a(isvu)", outSignature: "ai" },
    AboutToShow: { inSignature: "i", outSignature: "b" }, AboutToShowGroup: { inSignature: "ai", outSignature: "aiai" },
  },
  signals: {
    LayoutUpdated: { signature: "ui" }, ItemsPropertiesUpdated: { signature: "a(ia{sv})a(ias)" },
  },
});
