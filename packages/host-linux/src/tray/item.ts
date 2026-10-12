import dbus from "dbus-next";
const { Interface } = dbus.interface;

/** Network-order ARGB, no icon theme installation or toolkit needed. */
export function iconPixmap(): [number, number, Buffer][] {
  const size = 24;
  const pixels = Buffer.alloc(size * size * 4);
  const rgb = [0xe8, 0xe8, 0xe8];
  for (let y = 3; y < 21; y++) {
    for (let x = 3; x < 21; x++) {
      // A small lattice of four outlined cells.
      if (x === 3 || x === 11 || x === 12 || x === 20 || y === 3 || y === 11 || y === 12 || y === 20) {
        pixels.set([255, ...rgb], (y * size + x) * 4);
      }
    }
  }
  return [[size, size, pixels]];
}

export class TrayItem extends Interface {
  readonly Category = "ApplicationStatus";
  readonly Id = "lattices-host";
  readonly Title = "Lattices";
  readonly Status = "Active";
  readonly WindowId = 0;
  readonly IconName = "";
  readonly IconThemePath = "";
  readonly OverlayIconName = "";
  readonly OverlayIconPixmap: unknown[] = [];
  readonly AttentionIconName = "";
  readonly AttentionIconPixmap: unknown[] = [];
  readonly AttentionMovieName = "";
  readonly ItemIsMenu = true;
  readonly Menu = "/Menu";

  constructor(private refresh: () => Promise<void>) { super("org.kde.StatusNotifierItem"); }
  get IconPixmap() { return iconPixmap(); }
  get ToolTip() { return ["", [], "Lattices", ""]; }

  async Activate(_x: number, _y: number) { await this.refresh(); }
  async SecondaryActivate(_x: number, _y: number) { await this.refresh(); }
  async ContextMenu(_x: number, _y: number) { await this.refresh(); }
  Scroll(_delta: number, _orientation: string) {}
  NewIcon() {}
  NewToolTip() {}
  NewStatus(status: string) { return status; }
}

const properties = Object.fromEntries(Object.entries({
  Category: "s", Id: "s", Title: "s", Status: "s", WindowId: "u", IconName: "s", IconThemePath: "s",
  IconPixmap: "a(iiay)", OverlayIconName: "s", OverlayIconPixmap: "a(iiay)", AttentionIconName: "s",
  AttentionIconPixmap: "a(iiay)", AttentionMovieName: "s", ToolTip: "(sa(iiay)ss)", ItemIsMenu: "b", Menu: "o",
}).map(([name, signature]) => [name, { signature, access: "read" as const }]));

TrayItem.configureMembers({
  properties,
  methods: {
    Activate: { inSignature: "ii" }, SecondaryActivate: { inSignature: "ii" }, ContextMenu: { inSignature: "ii" }, Scroll: { inSignature: "is" },
  },
  signals: { NewIcon: { signature: "" }, NewToolTip: { signature: "" }, NewStatus: { signature: "s" } },
});
