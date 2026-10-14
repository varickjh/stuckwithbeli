type UndoToastProps = {
    message: string;
    onUndo: () => void;
};

export function UndoToast({ message, onUndo }: UndoToastProps) {
    return (
        // Above the batch bar (bottom-8) so the two never stack on each other,
        // and below the ranking overlay so it can't be clicked mid-run.
        <div className="pointer-events-none fixed inset-x-0 bottom-24 z-[45] flex justify-center px-4">
            <div
                className="pointer-events-auto flex items-center gap-4 rounded-full bg-ink py-2.5 pl-6 pr-2.5 text-white shadow-lg"
                role="status"
                aria-live="polite"
            >
                <span className="text-sm font-semibold">{message}</span>
                <button
                    className="rounded-full bg-white px-4 py-1.5 text-sm font-bold text-ink transition-colors hover:bg-card focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
                    type="button"
                    onClick={onUndo}
                >
                    Undo
                </button>
            </div>
        </div>
    );
}
