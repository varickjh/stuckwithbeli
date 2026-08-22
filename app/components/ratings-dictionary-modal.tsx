import { useEffect, useRef, useState } from "react";

import { existingRatingsSchema, type ExistingRatings } from "../lib/stack-schema";

type RatingsDictionaryModalProps = {
    entries: ExistingRatings;
    syncedAt: string | null;
    onSave: (entries: ExistingRatings) => void;
    onClose: () => void;
};

type ExportStatus = {
    id: string;
    state: "running" | "complete" | "error" | "cancelled";
    message: string | null;
    entries: Record<string, number> | null;
    error: string | null;
};

type SyncState =
    | { status: "idle" }
    | { status: "running"; sessionId: string; message: string | null }
    | { status: "error"; error: string };

export function RatingsDictionaryModal({
    entries,
    syncedAt,
    onSave,
    onClose,
}: RatingsDictionaryModalProps) {
    const [draft, setDraft] = useState(() =>
        Object.keys(entries).length ? JSON.stringify(entries, null, 2) : "",
    );
    const [error, setError] = useState<string | null>(null);
    const [syncState, setSyncState] = useState<SyncState>({ status: "idle" });
    const pollRef = useRef<number | null>(null);

    useEffect(() => {
        return () => {
            if (pollRef.current !== null) window.clearInterval(pollRef.current);
        };
    }, []);

    const entryCount = Object.keys(entries).length;

    const stopPolling = () => {
        if (pollRef.current !== null) {
            window.clearInterval(pollRef.current);
            pollRef.current = null;
        }
    };

    const startSync = async () => {
        setError(null);
        try {
            const response = await fetch("/api/ratings/export", { method: "POST" });
            const body = (await response.json()) as ExportStatus | { error?: string };
            if (!response.ok || !("id" in body)) {
                setSyncState({
                    status: "error",
                    error:
                        "error" in body && body.error
                            ? body.error
                            : "Could not start the sync.",
                });
                return;
            }
            setSyncState({ status: "running", sessionId: body.id, message: null });
            pollRef.current = window.setInterval(() => {
                void fetch(`/api/ratings/export?sessionId=${encodeURIComponent(body.id)}`)
                    .then(async (pollResponse) => {
                        if (!pollResponse.ok) return;
                        const status = (await pollResponse.json()) as ExportStatus;
                        if (status.state === "running") {
                            setSyncState({
                                status: "running",
                                sessionId: body.id,
                                message: status.message,
                            });
                            return;
                        }
                        stopPolling();
                        if (status.state === "complete" && status.entries) {
                            const merged = { ...entries, ...status.entries };
                            setDraft(JSON.stringify(merged, null, 2));
                            onSave(merged);
                            setSyncState({ status: "idle" });
                        } else if (status.state === "error") {
                            setSyncState({
                                status: "error",
                                error: status.error ?? "The sync failed.",
                            });
                        } else {
                            setSyncState({ status: "idle" });
                        }
                    })
                    .catch(() => undefined);
            }, 700);
        } catch (syncError) {
            setSyncState({
                status: "error",
                error:
                    syncError instanceof Error
                        ? syncError.message
                        : "Could not start the sync.",
            });
        }
    };

    const cancelSync = async () => {
        if (syncState.status !== "running") return;
        stopPolling();
        const sessionId = syncState.sessionId;
        setSyncState({ status: "idle" });
        await fetch("/api/ratings/export", {
            method: "DELETE",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ sessionId }),
        }).catch(() => undefined);
    };

    const save = () => {
        let parsed: unknown;
        try {
            parsed = JSON.parse(draft || "{}");
        } catch {
            setError("That isn't valid JSON.");
            return;
        }
        const result = existingRatingsSchema.safeParse(parsed);
        if (!result.success) {
            setError(
                "Expected an object of restaurant name to a score between 0 and 10.",
            );
            return;
        }
        setError(null);
        onSave(result.data);
        onClose();
    };

    return (
        <div
            className="fixed inset-0 z-[210] grid place-items-center bg-neutral-950/40 p-6"
            role="dialog"
            aria-modal="true"
            aria-labelledby="ratings-dictionary-title"
        >
            <div className="w-full max-w-lg rounded-sm bg-white p-8">
                <h2
                    className="m-0 text-xl font-semibold tracking-[-0.025em] text-neutral-950"
                    id="ratings-dictionary-title"
                >
                    My existing ratings
                </h2>
                <p className="mt-2 text-sm text-neutral-500">
                    {entryCount
                        ? `${entryCount} restaurant${entryCount === 1 ? "" : "s"} loaded${
                              syncedAt
                                  ? ` · last updated ${new Date(syncedAt).toLocaleString()}`
                                  : ""
                          }`
                        : "No ratings loaded yet."}
                </p>

                <div className="mt-4 rounded-sm bg-neutral-100 p-4">
                    <p className="text-sm text-neutral-700">
                        On the mirrored iPhone, open Beli and navigate to your own
                        ratings list so it&apos;s visible on screen, then sync — this
                        scrolls through and reads whatever list is currently showing.
                    </p>
                    <div className="mt-3 flex items-center gap-3">
                        <button
                            className="rounded-sm bg-white px-4 py-2 text-sm text-neutral-800 transition-colors hover:bg-neutral-200 disabled:opacity-50"
                            type="button"
                            disabled={syncState.status === "running"}
                            onClick={() => void startSync()}
                        >
                            {syncState.status === "running"
                                ? "Syncing…"
                                : "Sync from Beli"}
                        </button>
                        {syncState.status === "running" ? (
                            <button
                                className="rounded-sm bg-white px-4 py-2 text-sm text-neutral-600 transition-colors hover:bg-neutral-200"
                                type="button"
                                onClick={() => void cancelSync()}
                            >
                                Cancel
                            </button>
                        ) : null}
                    </div>
                    {syncState.status === "running" && syncState.message ? (
                        <p className="mt-2 text-sm text-neutral-500">
                            {syncState.message}
                        </p>
                    ) : null}
                    {syncState.status === "error" ? (
                        <p className="mt-2 text-sm text-[#c25b5f]">{syncState.error}</p>
                    ) : null}
                </div>

                <p className="mt-4 text-sm text-neutral-500">
                    Or paste/edit the JSON directly — restaurant name to a score
                    (0–10):
                </p>

                <textarea
                    className="mt-2 min-h-64 w-full resize-none rounded-sm bg-neutral-100 p-4 font-mono text-xs text-neutral-950 outline-none placeholder:text-neutral-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-950"
                    aria-label="Existing ratings JSON"
                    value={draft}
                    placeholder={'{\n  "Joe\'s Pizza": 8.4,\n  "Blue Bottle Coffee": 7.1\n}'}
                    onChange={(event) => setDraft(event.target.value)}
                />
                {error ? <p className="mt-2 text-sm text-[#c25b5f]">{error}</p> : null}

                <div className="mt-6 flex gap-3">
                    <button
                        className="rounded-sm bg-neutral-100 px-6 py-3 text-sm text-neutral-800 transition-colors hover:bg-neutral-200"
                        type="button"
                        onClick={onClose}
                    >
                        Cancel
                    </button>
                    <button
                        className="rounded-sm bg-accent px-6 py-3 text-sm text-white transition-colors hover:bg-accent/85"
                        type="button"
                        onClick={save}
                    >
                        Save
                    </button>
                </div>
            </div>
        </div>
    );
}
