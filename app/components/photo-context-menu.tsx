import type { PhotoContextMenuState } from "../lib/photo-types";

type PhotoContextMenuProps = {
  menu: PhotoContextMenuState;
  onSplit: (clusterId: string, photoId: string) => void;
};

export function PhotoContextMenu({ menu, onSplit }: PhotoContextMenuProps) {
  return (
    <div
      className="fixed z-[60] min-w-[212px] rounded-2xl bg-white p-2 font-sans text-ink"
      role="menu"
      tabIndex={-1}
      style={{ left: menu.x, top: menu.y }}
      onContextMenu={(event) => event.preventDefault()}
    >
      <button
        className="w-full rounded-xl bg-transparent px-3.5 py-2.5 text-left text-sm font-semibold text-ink transition-colors hover:bg-card-2 focus:bg-card-2"
        type="button"
        role="menuitem"
        onClick={() => onSplit(menu.clusterId, menu.photoId)}
      >
        Split into separate meal
      </button>
    </div>
  );
}
