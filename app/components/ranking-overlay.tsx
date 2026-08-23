import { useEffect, useRef, useState } from "react";
import { FaCheck, FaMicrophone } from "react-icons/fa6";
import SquareLoader from "react-spinners/SquareLoader";

import type { Photo } from "../lib/photo-types";
import {
    RANKING_STEPS,
    type RankingSessionStatus,
    type RankingStepId,
} from "../lib/ranking-types";
import { PhotoImage } from "./photo-image";

export type RankFeedback = {
    rating: "liked" | "fine" | "disliked" | null;
    description: string;
    photoDescriptions: string[];
    score: number | null;
};

export type ScoreState =
    | { status: "idle" }
    | { status: "loading" }
    | { status: "ready"; score: number; reasoning: string }
    | { status: "error"; error: string };

type RankingOverlayProps = {
    restaurantName: string;
    photos: Photo[];
    launching: boolean;
    progress: RankingSessionStatus | null;
    scoreState: ScoreState;
    onComputeScore: (input: {
        rating: RankFeedback["rating"];
        text: string;
        source: "typed" | "voice";
    }) => void;
    onCancel: () => void;
    onCancelProcess: () => void;
    onContinue: (feedback: RankFeedback) => void;
    onReopenPhone: () => void;
    onTogglePause: () => void;
    onRetry: (step: RankingStepId) => void;
    onSkipStep: (step: RankingStepId) => void;
    onContinuePhotos: () => void;
    onSkipPhotos: () => void;
    onFinished: () => void;
};

type SpeechRecognitionLike = {
    lang: string;
    interimResults: boolean;
    continuous: boolean;
    onresult: ((event: unknown) => void) | null;
    onend: (() => void) | null;
    onerror: (() => void) | null;
    start: () => void;
    stop: () => void;
};

function getSpeechRecognitionConstructor(): (new () => SpeechRecognitionLike) | null {
    if (typeof window === "undefined") return null;
    const anyWindow = window as unknown as {
        SpeechRecognition?: new () => SpeechRecognitionLike;
        webkitSpeechRecognition?: new () => SpeechRecognitionLike;
    };
    return anyWindow.SpeechRecognition ?? anyWindow.webkitSpeechRecognition ?? null;
}

function extractTranscript(event: unknown): string {
    const results = (event as { results?: ArrayLike<ArrayLike<{ transcript?: string }>> })
        .results;
    if (!results) return "";
    return Array.from(results)
        .map((result) => result[0]?.transcript ?? "")
        .join(" ")
        .trim();
}

const ratings = [
    { value: "liked", label: "I liked it!", color: "bg-liked", tint: "bg-liked-tint" },
    { value: "fine", label: "It was fine", color: "bg-fine", tint: "bg-fine-tint" },
    { value: "disliked", label: "I didn’t like it", color: "bg-disliked", tint: "bg-disliked-tint" },
] as const;

const confetti = Array.from({ length: 42 }, (_, index) => ({
    id: index,
    left: `${(index * 37) % 100}%`,
    delay: `${(index % 9) * 0.09}s`,
    duration: `${1.8 + (index % 6) * 0.18}s`,
    color: ["#234b56", "#78b090", "#f5e2ac", "#e8b6b6"][index % 4],
}));

export function RankingOverlay({
    restaurantName,
    photos,
    launching,
    progress,
    scoreState,
    onComputeScore,
    onCancel,
    onCancelProcess,
    onContinue,
    onReopenPhone,
    onTogglePause,
    onRetry,
    onSkipStep,
    onContinuePhotos,
    onSkipPhotos,
    onFinished,
}: RankingOverlayProps) {
    const [rating, setRating] = useState<RankFeedback["rating"]>(null);
    const [description, setDescription] = useState("");
    const [reviewSource, setReviewSource] = useState<"typed" | "voice">("typed");
    const [editableScore, setEditableScore] = useState<number | null>(null);
    const [recording, setRecording] = useState(false);
    const [photoDescriptions, setPhotoDescriptions] = useState<Record<string, string>>(
        {},
    );
    const dialogRef = useRef<HTMLDivElement>(null);
    const recognitionRef = useRef<SpeechRecognitionLike | null>(null);
    const speechAvailable = getSpeechRecognitionConstructor() !== null;

    useEffect(() => {
        if (scoreState.status === "ready") setEditableScore(scoreState.score);
    }, [scoreState]);

    const toggleRecording = () => {
        if (recording) {
            recognitionRef.current?.stop();
            return;
        }
        const Recognition = getSpeechRecognitionConstructor();
        if (!Recognition) return;
        const recognition = new Recognition();
        recognition.lang = "en-US";
        recognition.interimResults = false;
        recognition.continuous = false;
        recognition.onresult = (event) => {
            const transcript = extractTranscript(event);
            if (transcript) {
                setDescription((current) =>
                    current.trim() ? `${current.trim()} ${transcript}` : transcript,
                );
                setReviewSource("voice");
            }
        };
        recognition.onend = () => setRecording(false);
        recognition.onerror = () => setRecording(false);
        recognitionRef.current = recognition;
        setRecording(true);
        recognition.start();
    };

    useEffect(() => {
        const previousOverflow = document.body.style.overflow;
        document.body.style.overflow = "hidden";
        dialogRef.current?.focus();

        const closeOnEscape = (event: globalThis.KeyboardEvent) => {
            if (
                event.key === "Escape" &&
                progress?.state !== "running" &&
                progress?.state !== "paused"
            ) {
                onCancel();
            }
        };
        window.addEventListener("keydown", closeOnEscape);

        return () => {
            document.body.style.overflow = previousOverflow;
            window.removeEventListener("keydown", closeOnEscape);
        };
    }, [onCancel, progress?.state]);

    const showingProgress = progress !== null;
    const completed = progress?.state === "complete";
    const celebrating = progress?.celebrating || completed;
    const finalScore =
        scoreState.status === "ready" ? (editableScore ?? scoreState.score) : null;

    return (
        <div
            ref={dialogRef}
            className="fixed inset-0 z-[200] grid min-h-0 grid-rows-[minmax(0,1fr)_minmax(280px,45vh)] bg-white outline-none lg:grid-cols-[minmax(0,1fr)_minmax(440px,38vw)] lg:grid-rows-1"
            role="dialog"
            aria-modal="true"
            aria-labelledby="ranking-title"
            tabIndex={-1}
        >
            <section className="flex min-h-0 flex-col bg-white">
                <div className="no-scrollbar flex min-h-0 flex-1 items-center overflow-y-auto px-8 py-8 sm:px-14 sm:py-14">
                    <div className="mx-auto grid w-full max-w-4xl grid-cols-[repeat(auto-fit,minmax(240px,340px))] justify-center gap-x-8 gap-y-10">
                        {photos.map((photo) => (
                            <div className="block min-w-0" key={photo.id}>
                                <span className="relative block aspect-square w-full overflow-hidden rounded-[20px] bg-card">
                                    <PhotoImage photo={photo} alt="" />
                                </span>
                                <input
                                    className="mt-4 w-full rounded-2xl bg-card px-4 py-3.5 text-base text-ink outline-none placeholder:text-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark"
                                    aria-label={`Dish description for ${photo.name}`}
                                    type="text"
                                    disabled={showingProgress}
                                    value={photoDescriptions[photo.id] ?? ""}
                                    placeholder="Dish name"
                                    onChange={(event) => {
                                        const value = event.target.value;
                                        setPhotoDescriptions((current) => ({
                                            ...current,
                                            [photo.id]: value,
                                        }));
                                    }}
                                />
                            </div>
                        ))}
                    </div>
                </div>
            </section>

            <section className="relative min-h-0 overflow-y-auto bg-warm px-8 py-10 sm:px-12 sm:py-12 lg:px-16 lg:py-16">
                {showingProgress && completed ? (
                    <div className="flex min-h-full flex-col items-center justify-center gap-4 text-center">
                        <div className="grid size-22 place-items-center rounded-full bg-accent">
                            <FaCheck className="size-9 text-white" aria-hidden="true" />
                        </div>
                        <h2
                            className="m-0 font-serif text-3xl font-bold text-accent-dark sm:text-4xl"
                            id="ranking-title"
                        >
                            Ranked!
                        </h2>
                        <p className="m-0 text-sm text-muted-2">
                            {restaurantName} added to your Beli list
                            {finalScore !== null ? ` at ${finalScore}` : ""}
                        </p>
                        <button
                            className="mt-2 rounded-full bg-accent px-10 py-3.5 text-base font-bold text-white transition-colors hover:bg-accent/85"
                            type="button"
                            onClick={onFinished}
                        >
                            Done
                        </button>
                        {celebrating ? (
                            <div className="pointer-events-none fixed inset-0 z-[220] overflow-hidden" aria-hidden="true">
                                {confetti.map((piece) => (
                                    <span
                                        className="ranking-confetti absolute -top-8 h-4 w-2"
                                        key={piece.id}
                                        style={{
                                            left: piece.left,
                                            animationDelay: piece.delay,
                                            animationDuration: piece.duration,
                                            backgroundColor: piece.color,
                                        }}
                                    />
                                ))}
                            </div>
                        ) : null}
                    </div>
                ) : showingProgress ? (
                    <div className="flex min-h-full flex-col" aria-live="polite">
                        <h2
                            className="m-0 font-serif text-3xl font-bold text-accent-dark sm:text-4xl"
                            id="ranking-title"
                        >
                            Ranking {restaurantName}
                        </h2>
                        <div className="mt-6 flex flex-wrap gap-3">
                            <button
                                className="rounded-full bg-white px-5 py-3 text-sm font-bold text-accent transition-colors hover:bg-card-2 disabled:opacity-50"
                                type="button"
                                disabled={launching}
                                onClick={onReopenPhone}
                            >
                                Reopen phone
                            </button>
                            {progress.state === "running" || progress.state === "paused" ? (
                                <button
                                    className="rounded-full bg-white px-5 py-3 text-sm font-semibold text-muted transition-colors hover:bg-card-2 disabled:opacity-50"
                                    type="button"
                                    disabled={launching}
                                    onClick={onTogglePause}
                                >
                                    {progress.state === "paused" ? "Resume" : "Pause"}
                                </button>
                            ) : null}
                            {progress.state === "running" || progress.state === "paused" ? (
                                <button
                                    className="rounded-full bg-white px-5 py-3 text-sm font-semibold text-muted transition-colors hover:bg-card-2 disabled:opacity-50"
                                    type="button"
                                    disabled={launching}
                                    onClick={onCancelProcess}
                                >
                                    Cancel
                                </button>
                            ) : (
                                <button
                                    className="rounded-full bg-white px-5 py-3 text-sm font-semibold text-muted transition-colors hover:bg-card-2 disabled:opacity-50"
                                    type="button"
                                    disabled={launching}
                                    onClick={onCancel}
                                >
                                    Close
                                </button>
                            )}
                        </div>

                        <ul className="mt-12 flex list-none flex-col p-0">
                            {RANKING_STEPS.filter(
                                (step) =>
                                    progress.steps[step.id] !== "pending" || completed,
                            ).map((step, index) => {
                                const state = progress.steps[step.id];
                                const showsError =
                                    progress.state === "error" && state === "active";
                                return (
                                    <li className="contents" key={step.id}>
                                        {index > 0 ? (
                                            <div
                                                className="ml-[13px] h-4 w-0.5 bg-divider"
                                                aria-hidden="true"
                                            />
                                        ) : null}
                                        <div
                                            className={`group/step flex items-start gap-4 pb-1 text-base ${state === "complete" ? "text-muted-2" : "text-ink"}`}
                                        >
                                            {state === "active" && progress.state === "running" ? (
                                                <span className="mt-1 grid size-6.5 shrink-0 place-items-center">
                                                    <SquareLoader
                                                        color="var(--color-accent)"
                                                        size={16}
                                                        speedMultiplier={1.15}
                                                        aria-label="In progress"
                                                    />
                                                </span>
                                            ) : state === "complete" ? (
                                                <span
                                                    className="mt-1 grid size-6.5 shrink-0 place-items-center rounded-full bg-accent text-white"
                                                    aria-hidden="true"
                                                >
                                                    <FaCheck className="size-3" />
                                                </span>
                                            ) : (
                                                <span
                                                    className="mt-1 size-6.5 shrink-0 rounded-full bg-skeleton"
                                                    aria-hidden="true"
                                                />
                                            )}
                                            <div className="min-w-0 flex-1">
                                                <div className="flex items-start gap-3">
                                                    <span>{step.label}</span>
                                                    <div className="ml-auto flex gap-2 opacity-0 transition-opacity group-hover/step:opacity-100 group-focus-within/step:opacity-100">
                                                        <button
                                                            className="rounded-full bg-white px-3 py-2 text-xs font-semibold text-muted transition-colors hover:bg-card-2 disabled:cursor-default disabled:opacity-50"
                                                            type="button"
                                                            disabled={launching}
                                                            onClick={() => onRetry(step.id)}
                                                        >
                                                            Retry from here
                                                        </button>
                                                        <button
                                                            className="rounded-full bg-white px-3 py-2 text-xs font-semibold text-muted transition-colors hover:bg-card-2 disabled:cursor-default disabled:opacity-50"
                                                            type="button"
                                                            disabled={launching}
                                                            onClick={() => onSkipStep(step.id)}
                                                        >
                                                            Skip
                                                        </button>
                                                    </div>
                                                </div>
                                                {showsError ? (
                                                    <div className="mt-2">
                                                        <p className="text-sm text-error">
                                                            {progress.error}
                                                        </p>
                                                        {progress.recovery === "photos_not_found" ? (
                                                            <div className="mt-4 flex flex-wrap gap-3">
                                                                <button
                                                                    className="rounded-full bg-accent px-6 py-3 text-sm font-bold text-white transition-colors hover:bg-accent/85 disabled:opacity-50"
                                                                    type="button"
                                                                    disabled={launching}
                                                                    onClick={onContinuePhotos}
                                                                >
                                                                    Continue with added photos
                                                                </button>
                                                                <button
                                                                    className="rounded-full bg-white px-6 py-3 text-sm font-semibold text-ink transition-colors hover:bg-card-2 disabled:opacity-50"
                                                                    type="button"
                                                                    disabled={launching}
                                                                    onClick={onSkipPhotos}
                                                                >
                                                                    Skip photos
                                                                </button>
                                                            </div>
                                                        ) : null}
                                                    </div>
                                                ) : null}
                                                {step.id === "finish_in_beli" &&
                                                progress.duelLog.length ? (
                                                    <div className="mt-3 flex flex-col gap-2 rounded-2xl bg-white p-4">
                                                        <span className="text-xs font-bold text-muted">
                                                            Duel log
                                                        </span>
                                                        {progress.duelLog.map((entry, duelIndex) => (
                                                            <div
                                                                className="rounded-xl bg-card px-3 py-2 font-mono text-xs text-ink"
                                                                key={duelIndex}
                                                            >
                                                                {entry.message}
                                                            </div>
                                                        ))}
                                                    </div>
                                                ) : null}
                                            </div>
                                        </div>
                                    </li>
                                );
                            })}
                        </ul>

                        {celebrating ? (
                            <div className="pointer-events-none fixed inset-0 z-[220] overflow-hidden" aria-hidden="true">
                                {confetti.map((piece) => (
                                    <span
                                        className="ranking-confetti absolute -top-8 h-4 w-2"
                                        key={piece.id}
                                        style={{
                                            left: piece.left,
                                            animationDelay: piece.delay,
                                            animationDuration: piece.duration,
                                            backgroundColor: piece.color,
                                        }}
                                    />
                                ))}
                            </div>
                        ) : null}
                    </div>
                ) : (
                    <>
                        <h2
                            className="m-0 font-serif text-3xl font-bold text-accent-dark sm:text-4xl"
                            id="ranking-title"
                        >
                            How was {restaurantName}?
                        </h2>

                        <div className="mt-9 flex flex-col gap-3">
                            {ratings.map((option) => {
                                const selected = rating === option.value;
                                return (
                                    <button
                                        className={`flex items-center gap-5 rounded-2xl px-4 py-3 text-left text-base font-semibold text-ink transition-colors ${selected ? option.tint : "bg-white"}`}
                                        type="button"
                                        aria-pressed={selected}
                                        key={option.value}
                                        onClick={() => setRating(option.value)}
                                    >
                                        <span
                                            className={`grid size-16 shrink-0 place-items-center rounded-full ${option.color} transition-transform hover:scale-105`}
                                            aria-hidden="true"
                                        >
                                            {selected ? (
                                                <FaCheck className="size-6 text-white" />
                                            ) : null}
                                        </span>
                                        <span>{option.label}</span>
                                    </button>
                                );
                            })}
                        </div>

                        <div className="relative mt-10">
                            <textarea
                                className="min-h-56 w-full resize-none rounded-2xl bg-white p-5 pr-14 text-base font-normal text-ink outline-none placeholder:text-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark"
                                aria-label="Review"
                                value={description}
                                placeholder="Add a review, typed or by voice (optional)"
                                onChange={(event) => {
                                    setDescription(event.target.value);
                                    setReviewSource("typed");
                                }}
                            />
                            {speechAvailable ? (
                                <button
                                    className={`absolute right-4 top-4 grid size-10 place-items-center rounded-full transition-colors ${recording ? "bg-accent text-white" : "bg-card-2 text-muted hover:bg-divider"}`}
                                    type="button"
                                    aria-pressed={recording}
                                    aria-label={recording ? "Stop recording" : "Record a review"}
                                    onClick={toggleRecording}
                                >
                                    <FaMicrophone className="size-4" />
                                </button>
                            ) : null}
                        </div>

                        {scoreState.status === "ready" || scoreState.status === "error" ? (
                            <div className="mt-5 flex flex-col gap-3">
                                {scoreState.status === "ready" ? (
                                    <div className="rounded-2xl bg-white p-5 text-sm text-ink">
                                        <label className="flex items-center gap-3">
                                            <span className="text-xs font-bold text-muted">
                                                Score
                                            </span>
                                            <input
                                                className="w-16 rounded-full bg-liked-tint px-3 py-1 text-sm font-bold text-score-good outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark"
                                                type="number"
                                                min={0}
                                                max={10}
                                                step={0.1}
                                                value={editableScore ?? scoreState.score}
                                                onChange={(event) =>
                                                    setEditableScore(
                                                        Number(event.target.value),
                                                    )
                                                }
                                            />
                                        </label>
                                        <p className="mt-2 text-muted">
                                            {scoreState.reasoning}
                                        </p>
                                    </div>
                                ) : null}
                                {scoreState.status === "error" ? (
                                    <p className="text-sm text-error">
                                        {scoreState.error}
                                    </p>
                                ) : null}
                            </div>
                        ) : null}

                        <div className="mt-6 flex gap-3">
                            <button
                                className="rounded-full bg-card-2 px-7 py-3.5 text-base font-bold text-ink transition-colors hover:bg-divider disabled:opacity-50"
                                type="button"
                                disabled={launching}
                                onClick={onCancel}
                            >
                                Cancel
                            </button>
                            <button
                                className="flex-1 rounded-full bg-accent px-7 py-3.5 text-base font-bold text-white transition-colors hover:bg-accent/85 disabled:opacity-50"
                                type="button"
                                disabled={launching || !rating || scoreState.status === "loading"}
                                onClick={() => {
                                    const needsScore = scoreState.status !== "ready";
                                    if (needsScore) {
                                        onComputeScore({
                                            rating,
                                            text: description,
                                            source: reviewSource,
                                        });
                                        return;
                                    }
                                    onContinue({
                                        rating,
                                        description,
                                        photoDescriptions: photos.map((photo) =>
                                            photoDescriptions[photo.id]?.trim() || "Menu"
                                        ),
                                        score:
                                            scoreState.status === "ready"
                                                ? (editableScore ?? scoreState.score)
                                                : null,
                                    });
                                }}
                            >
                                {scoreState.status === "loading"
                                    ? "Computing score…"
                                    : "Continue"}
                            </button>
                        </div>
                    </>
                )}
            </section>
        </div>
    );
}
