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
            <div className="flex items-center gap-2 justify-self-start">
                <button
                    className="w-fit rounded-full bg-accent px-4.5 py-2.5 font-sans text-[14px] font-semibold text-white transition-colors hover:bg-accent/85 disabled:cursor-not-allowed disabled:opacity-50"
                    type="button"
                    onClick={onChooseFiles}
                    disabled={processing || labeling}
                >
                    {hasPhotos ? "Add photos" : "Choose files"}
                </button>
                <button
                    className="w-fit rounded-full bg-card-2 px-4.5 py-2.5 font-sans text-[14px] font-semibold text-accent transition-colors hover:bg-divider"
                    type="button"
                    onClick={onOpenRatingsDictionary}
                >
                    My ratings
                </button>
                {hasPhotos ? (
                    <button
                        className="w-fit rounded-full bg-card-2 px-4.5 py-2.5 font-sans text-[14px] font-semibold text-muted transition-colors hover:bg-divider disabled:cursor-not-allowed disabled:opacity-50"
                        type="button"
                        onClick={onClear}
                        disabled={processing || labeling}
                    >
                        Clear
                    </button>
                ) : null}
            </div>

            <Link
                className="font-serif text-[clamp(28px,2.6vw,36px)] font-bold italic leading-none tracking-[-0.02em] text-accent-dark no-underline max-[680px]:col-start-2 max-[680px]:row-start-1 max-[680px]:text-[26px]"
                href="/"
                aria-label="stuckwithfood home"
            >
                stuckwithfood
            </Link>

            {unlabeledCount > 0 ? (
                <button
                    className="w-fit justify-self-end rounded-full bg-accent px-5 py-2.5 font-sans text-[14px] font-bold text-white transition-colors hover:bg-accent/85 disabled:cursor-not-allowed disabled:opacity-50 max-[680px]:col-span-2 max-[680px]:w-full"
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
