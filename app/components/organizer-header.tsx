import Link from "next/link";

type OrganizerHeaderProps = {
    hasPhotos: boolean;
    processing: boolean;
    labeling: boolean;
    mealCount: number;
    unlabeledCount: number;
    onChooseFiles: () => void;
    onClear: () => void;
    onLabel: () => void;
    onOpenRatingsDictionary: () => void;
};

export function OrganizerHeader({
    hasPhotos,
    processing,
    labeling,
    mealCount,
    unlabeledCount,
    onChooseFiles,
    onClear,
    onLabel,
    onOpenRatingsDictionary,
}: OrganizerHeaderProps) {
    const labelText =
        unlabeledCount === mealCount
            ? "Label all"
            : `Label ${unlabeledCount} meal${unlabeledCount === 1 ? "" : "s"}`;

    return (
        <header className="relative z-10 mx-auto grid w-full max-w-7xl grid-cols-[1fr_auto_1fr] items-center gap-6 py-6 max-[680px]:grid-cols-[1fr_auto]">
            <div className="flex items-center gap-3 justify-self-start">
                <button
                    className="rounded-sm w-fit bg-neutral-100 px-4 py-3 font-sans text-[15px] text-neutral-700 transition-colors hover:bg-neutral-200 disabled:cursor-not-allowed disabled:opacity-50"
                    type="button"
                    onClick={onChooseFiles}
                    disabled={processing || labeling}
                >
                    {hasPhotos ? "Add photos" : "Choose files"}
                </button>
                <button
                    className="rounded-sm w-fit bg-transparent px-4 py-3 font-sans text-[15px] text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-700"
                    type="button"
                    onClick={onOpenRatingsDictionary}
                >
                    My ratings
                </button>
                {hasPhotos ? (
                    <button
                        className="rounded-sm w-fit bg-transparent px-4 py-3 font-sans text-[15px] text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-700 disabled:cursor-not-allowed disabled:opacity-50"
                        type="button"
                        onClick={onClear}
                        disabled={processing || labeling}
                    >
                        Clear
                    </button>
                ) : null}
            </div>

            <Link
                className="font-serif text-[clamp(30px,3vw,42px)] font-medium leading-none tracking-[-0.035em] text-neutral-950 no-underline max-[680px]:col-start-2 max-[680px]:row-start-1 max-[680px]:text-[29px]"
                href="/"
                aria-label="Auto Beli home"
            >
                Auto <span className="text-accent">Beli</span>
            </Link>

            {unlabeledCount > 0 ? (
                <button
                    className="rounded-sm w-fit justify-self-end bg-accent px-4 py-3 font-sans text-[15px] text-white transition-colors hover:bg-accent/85 disabled:cursor-not-allowed disabled:opacity-50 max-[680px]:col-span-2 max-[680px]:w-full"
                    type="button"
                    disabled={processing || labeling}
                    onClick={onLabel}
                >
                    {labeling ? "Labeling…" : labelText}
                </button>
            ) : null}
        </header>
    );
}
