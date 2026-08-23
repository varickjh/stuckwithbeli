import Image from "next/image";

const placeholderImages = [
    {
        src: "/food-placeholders/ramen.png",
        className:
            "z-40 left-[26%] top-[2%] -rotate-3 group-hover:-translate-y-2 group-hover:-rotate-6",
    },
    {
        src: "/food-placeholders/croissant.png",
        className:
            "z-30 right-[3%] top-[12%] rotate-6 group-hover:translate-x-2 group-hover:-translate-y-0.5 group-hover:rotate-9",
    },
    {
        src: "/food-placeholders/cake.png",
        className:
            "z-20 bottom-[1%] right-[25%] rotate-2 group-hover:translate-y-2 group-hover:rotate-3",
    },
    {
        src: "/food-placeholders/dumplings.png",
        className:
            "z-10 bottom-[10%] left-[2%] -rotate-9 group-hover:-translate-x-2 group-hover:translate-y-1 group-hover:-rotate-12",
    },
];

type EmptyUploadProps = {
    processing: boolean;
    message: string;
    onChooseFiles: () => void;
};

export function EmptyUpload({
    processing,
    message,
    onChooseFiles,
}: EmptyUploadProps) {
    return (
        <section
            className="mx-auto flex min-h-[calc(100vh-160px)] max-w-7xl flex-col items-center justify-center pb-24"
            aria-live="polite"
        >
            <div className="flex w-full max-w-3xl flex-col items-center gap-5 rounded-[32px] bg-accent-tint px-10 py-16 text-center">
                <button
                    className="group relative mb-2 h-[min(40vw,220px)] w-[min(52vw,300px)] bg-transparent transition-opacity hover:opacity-80 disabled:cursor-wait disabled:opacity-60"
                    type="button"
                    onClick={onChooseFiles}
                    disabled={processing}
                    aria-label="Choose photos or zip files"
                >
                    {placeholderImages.map(({ src, className }, index) => (
                        <span
                            className={`absolute block aspect-square w-32 overflow-hidden rounded-2xl bg-white transition-transform duration-300 ${className}`}
                            key={src}
                        >
                            <Image
                                src={src}
                                alt=""
                                fill
                                priority={index === 0}
                                sizes="160px"
                                className="object-cover grayscale"
                            />
                        </span>
                    ))}
                </button>

                <h1 className="m-0 font-serif text-3xl font-bold leading-none tracking-[-0.02em] text-accent-dark">
                    {processing ? "Sorting your photos…" : "Drop photos here"}
                </h1>
                <p className="m-0 text-sm text-accent">
                    {processing
                        ? ""
                        : "or choose files from your computer — we'll sort them into meals automatically"}
                </p>
                <button
                    className="mt-2 w-fit rounded-full bg-accent px-8 py-3.5 font-sans text-[15px] font-bold text-white transition-colors hover:bg-accent/85 disabled:cursor-not-allowed disabled:opacity-60"
                    type="button"
                    onClick={onChooseFiles}
                    disabled={processing}
                >
                    Choose files
                </button>
            </div>
        </section>
    );
}
