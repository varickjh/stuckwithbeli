"use client";

import type {
    ChangeEvent,
    DragEvent,
    MouseEvent as ReactMouseEvent,
} from "react";
import { useEffect, useRef, useState } from "react";

import { EmptyUpload } from "./components/empty-upload";
import { OrganizerHeader } from "./components/organizer-header";
import { PhotoClusterCard } from "./components/photo-cluster-card";
import { PhotoContextMenu } from "./components/photo-context-menu";
import {
    type RankFeedback,
    type ScoreState,
    RankingOverlay,
} from "./components/ranking-overlay";
import { RatingsDictionaryModal } from "./components/ratings-dictionary-modal";
import {
    addPhotosToClusters,
    checksumBlob,
    clusterCoordinate,
    clusterCity,
    processFiles,
} from "./lib/photo-processing";
import {
    clearBrowserData,
    loadClusters,
    loadRatingsDictionary,
    saveClusters,
    saveLabelLog,
    saveRatingsDictionary,
    saveScoreLog,
} from "./lib/browser-storage";
import { resizePhotosForLabeling } from "./lib/image-resize";
import {
    PHOTO_DRAG_TYPE,
    type PhotoCluster,
    type PhotoContextMenuState,
} from "./lib/photo-types";
import type {
    RankingSessionStatus,
    RankingStepId,
} from "./lib/ranking-types";
import {
    labelStackResponseSchema,
    scoreStackResponseSchema,
    type ExistingRatings,
    type MealCategory,
    type RestaurantSelection,
} from "./lib/stack-schema";

export default function Home() {
    const [clusters, setClusters] = useState<PhotoCluster[]>([]);
    const [processing, setProcessing] = useState(false);
    const [labeling, setLabeling] = useState(false);
    const [hydrated, setHydrated] = useState(false);
    const [message, setMessage] = useState("Drop photos or a zip anywhere");
    const [draggingOver, setDraggingOver] = useState(false);
    const [draggedPhotoId, setDraggedPhotoId] = useState<string | null>(null);
    const [dropTargetClusterId, setDropTargetClusterId] = useState<string | null>(
        null,
    );
    const [photoContextMenu, setPhotoContextMenu] =
        useState<PhotoContextMenuState | null>(null);
    const [rankingClusterId, setRankingClusterId] = useState<string | null>(null);
    const [rankingLaunching, setRankingLaunching] = useState(false);
    const [rankingProgress, setRankingProgress] =
        useState<RankingSessionStatus | null>(null);
    const [ratingsDictionary, setRatingsDictionary] = useState<{
        entries: ExistingRatings;
        syncedAt: string | null;
    }>({ entries: {}, syncedAt: null });
    const [ratingsDictionaryOpen, setRatingsDictionaryOpen] = useState(false);
    const [scoreState, setScoreState] = useState<ScoreState>({ status: "idle" });
    const rankingSessionId = rankingProgress?.id ?? null;
    const rankingSessionState = rankingProgress?.state ?? null;
    const inputRef = useRef<HTMLInputElement>(null);
    const objectUrls = useRef<string[]>([]);

    useEffect(() => {
        const urls = objectUrls;
        return () => urls.current.forEach((url) => URL.revokeObjectURL(url));
    }, []);

    useEffect(() => {
        let cancelled = false;
        void loadClusters()
            .then(async (savedClusters) => {
                if (cancelled) return;
                const restored = await Promise.all(
                    savedClusters.map(async (cluster) => ({
                        ...cluster,
                        ranked: cluster.ranked ?? false,
                        labelStatus:
                            cluster.labelStatus === "matching" ||
                                cluster.labelStatus === "queued"
                                ? ("ready" as const)
                                : (cluster.labelStatus ?? "ready"),
                        placesSearch: cluster.placesSearch ?? null,
                        match: cluster.match ?? null,
                        category: cluster.category ?? cluster.match?.category ?? null,
                        selection: cluster.selection ?? null,
                        labelError: cluster.labelError ?? null,
                        photos: await Promise.all(
                            cluster.photos.map(async (photo) => {
                                const url = URL.createObjectURL(photo.blob);
                                objectUrls.current.push(url);
                                return {
                                    ...photo,
                                    checksum:
                                        photo.checksum ?? await checksumBlob(photo.blob),
                                    url,
                                };
                            }),
                        ),
                    })),
                );
                if (cancelled) return;
                setClusters(restored);
                if (restored.length) setMessage("");
            })
            .catch((error) => console.error("Could not restore saved photos", error))
            .finally(() => {
                if (!cancelled) setHydrated(true);
            });

        return () => {
            cancelled = true;
        };
    }, []);

    useEffect(() => {
        void loadRatingsDictionary()
            .then((dictionary) => {
                if (dictionary) {
                    setRatingsDictionary({
                        entries: dictionary.entries,
                        syncedAt: dictionary.syncedAt,
                    });
                }
            })
            .catch((error) =>
                console.error("Could not restore saved ratings", error),
            );
    }, []);

    useEffect(() => {
        if (!hydrated) return;
        void saveClusters(clusters).catch((error) =>
            console.error("Could not save photo progress", error),
        );
    }, [clusters, hydrated]);

    useEffect(() => {
        const closeMenu = () => setPhotoContextMenu(null);
        const closeMenuOnEscape = (event: globalThis.KeyboardEvent) => {
            if (event.key === "Escape") closeMenu();
        };

        window.addEventListener("click", closeMenu);
        window.addEventListener("blur", closeMenu);
        window.addEventListener("resize", closeMenu);
        window.addEventListener("scroll", closeMenu, true);
        window.addEventListener("keydown", closeMenuOnEscape);

        return () => {
            window.removeEventListener("click", closeMenu);
            window.removeEventListener("blur", closeMenu);
            window.removeEventListener("resize", closeMenu);
            window.removeEventListener("scroll", closeMenu, true);
            window.removeEventListener("keydown", closeMenuOnEscape);
        };
    }, []);

    useEffect(() => {
        if (!rankingSessionId || rankingSessionState !== "running") return;
        const controller = new AbortController();
        const sessionId = rankingSessionId;
        const interval = window.setInterval(() => {
            void fetch(`/api/rank?sessionId=${encodeURIComponent(sessionId)}`, {
                signal: controller.signal,
            })
                .then(async (response) => {
                    if (!response.ok) return;
                    const status = (await response.json()) as RankingSessionStatus;
                    setRankingProgress(status);
                })
                .catch(() => undefined);
        }, 700);

        return () => {
            controller.abort();
            window.clearInterval(interval);
        };
    }, [rankingSessionId, rankingSessionState]);

    const chooseFiles = () => inputRef.current?.click();

    const addFiles = async (files: File[]) => {
        if (!files.length) return;
        setProcessing(true);
        setMessage("Reading photos and metadata…");

        try {
            const photos = await processFiles(
                files,
                clusters.flatMap((cluster) =>
                    cluster.photos.map((photo) => photo.checksum),
                ),
            );
            objectUrls.current.push(...photos.map((photo) => photo.url));
            setClusters((current) => addPhotosToClusters(current, photos));
            setMessage(
                photos.length
                    ? `${photos.length} photo${photos.length === 1 ? "" : "s"} added`
                    : "No new photos added",
            );
        } catch (error) {
            console.error(error);
            setMessage("That upload could not be read. Try the images or zip again.");
        } finally {
            setProcessing(false);
        }
    };

    const handleFileInput = (event: ChangeEvent<HTMLInputElement>) => {
        void addFiles(Array.from(event.target.files ?? []));
        event.target.value = "";
    };

    const handlePageDrop = (event: DragEvent<HTMLElement>) => {
        if (Array.from(event.dataTransfer.types).includes(PHOTO_DRAG_TYPE)) return;
        event.preventDefault();
        setDraggingOver(false);
        void addFiles(Array.from(event.dataTransfer.files));
    };

    const movePhoto = (photoId: string, targetClusterId: string) => {
        setClusters((current) => {
            const source = current.find((cluster) =>
                cluster.photos.some((photo) => photo.id === photoId),
            );
            if (!source || source.id === targetClusterId) return current;

            const photo = source.photos.find((item) => item.id === photoId);
            if (!photo) return current;

            return current
                .map((cluster) => {
                    if (cluster.id === source.id) {
                        return {
                            ...cluster,
                            photos: cluster.photos.filter((item) => item.id !== photoId),
                        };
                    }
                    if (cluster.id === targetClusterId) {
                        return { ...cluster, photos: [photo, ...cluster.photos] };
                    }
                    return cluster;
                })
                .filter((cluster) => cluster.photos.length > 0);
        });
        setDraggedPhotoId(null);
        setDropTargetClusterId(null);
    };

    const bringPhotoToFront = (clusterId: string, photoId: string) => {
        setClusters((current) =>
            current.map((cluster) => {
                if (cluster.id !== clusterId || cluster.photos[0]?.id === photoId) {
                    return cluster;
                }

                const selected = cluster.photos.find((photo) => photo.id === photoId);
                if (!selected) return cluster;

                return {
                    ...cluster,
                    photos: [
                        selected,
                        ...cluster.photos.filter((photo) => photo.id !== photoId),
                    ],
                };
            }),
        );
    };

    const deletePhoto = (photoId: string) => {
        setClusters((current) => {
            const photo = current
                .flatMap((cluster) => cluster.photos)
                .find((item) => item.id === photoId);
            if (photo) {
                URL.revokeObjectURL(photo.url);
                objectUrls.current = objectUrls.current.filter(
                    (url) => url !== photo.url,
                );
            }

            return current
                .map((cluster) => ({
                    ...cluster,
                    photos: cluster.photos.filter((item) => item.id !== photoId),
                }))
                .filter((cluster) => cluster.photos.length > 0);
        });
    };

    const splitIntoSeparateMeal = (clusterId: string, photoId: string) => {
        setClusters((current) => {
            const source = current.find((cluster) => cluster.id === clusterId);
            const photo = source?.photos.find((item) => item.id === photoId);
            if (!source || !photo || source.photos.length === 1) return current;

            return current.flatMap((cluster) =>
                cluster.id === clusterId
                    ? [
                        {
                            ...cluster,
                            photos: cluster.photos.filter((item) => item.id !== photoId),
                        },
                        {
                            id: crypto.randomUUID(),
                            photos: [photo],
                            ranked: false,
                            labelStatus: "ready",
                            placesSearch: null,
                            match: null,
                            category: null,
                            selection: null,
                            labelError: null,
                        },
                    ]
                    : [cluster],
            );
        });
        setPhotoContextMenu(null);
    };

    const selectRestaurant = (
        clusterId: string,
        selection: RestaurantSelection,
    ) => {
        setClusters((current) =>
            current.map((cluster) =>
                cluster.id === clusterId ? { ...cluster, selection } : cluster,
            ),
        );
    };

    const selectCategory = (clusterId: string, category: MealCategory) => {
        setClusters((current) =>
            current.map((cluster) =>
                cluster.id === clusterId ? { ...cluster, category } : cluster,
            ),
        );
    };

    const clearAll = () => {
        if (!window.confirm("Clear all photos, labels, and saved progress?")) return;
        objectUrls.current.forEach((url) => URL.revokeObjectURL(url));
        objectUrls.current = [];
        setClusters([]);
        setMessage("Drop photos or a zip anywhere");
        void clearBrowserData().catch((error) =>
            console.error("Could not clear saved progress", error),
        );
    };

    const labelClusters = async (targets: PhotoCluster[]) => {
        if (!targets.length || labeling) return;
        const targetIds = new Set(targets.map((cluster) => cluster.id));
        const runId = crypto.randomUUID();
        setLabeling(true);
        setMessage(`Labeling ${targets.length} meal${targets.length === 1 ? "" : "s"}…`);
        setClusters((current) =>
            current.map((cluster) =>
                targetIds.has(cluster.id)
                    ? { ...cluster, labelStatus: "queued", labelError: null }
                    : cluster,
            ),
        );

        let completed = 0;
        let failed = 0;
        for (const cluster of targets) {
            setClusters((current) =>
                current.map((item) =>
                    item.id === cluster.id
                        ? { ...item, labelStatus: "matching" }
                        : item,
                ),
            );

            try {
                const coordinate = clusterCoordinate(cluster);
                if (!coordinate) throw new Error("Location unavailable");
                const photos = await resizePhotosForLabeling(cluster.photos);
                if (!photos.length) throw new Error("These photos could not be resized");

                const request = await fetch("/api/label", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        runId,
                        stackId: cluster.id,
                        coordinate,
                        photos,
                    }),
                });
                const body = (await request.json()) as unknown;
                if (!request.ok) {
                    const errorBody = body as { error?: string };
                    throw new Error(errorBody.error ?? "Labeling failed");
                }
                const response = labelStackResponseSchema.parse(body);
                await saveLabelLog(runId, cluster.id, response);
                setClusters((current) =>
                    current.map((item) =>
                        item.id === cluster.id
                            ? {
                                ...item,
                                labelStatus: "matched",
                                placesSearch: response.placesSearch,
                                match: response.match,
                                category: response.match.category,
                                selection: response.match.selected,
                                labelError: null,
                            }
                            : item,
                    ),
                );
            } catch (error) {
                failed += 1;
                const labelError =
                    error instanceof Error ? error.message : "Labeling failed";
                setClusters((current) =>
                    current.map((item) =>
                        item.id === cluster.id
                            ? { ...item, labelStatus: "error", labelError }
                            : item,
                    ),
                );
            }

            completed += 1;
            setMessage(
                failed
                    ? `${completed} of ${targets.length} checked · ${failed} needs attention`
                    : `${completed} of ${targets.length} meals labeled`,
            );
        }

        setLabeling(false);
    };

    const openPhotoContextMenu = (
        event: ReactMouseEvent<HTMLElement>,
        clusterId: string,
        photoId: string,
    ) => {
        event.preventDefault();
        event.stopPropagation();
        setPhotoContextMenu({
            clusterId,
            photoId,
            x: Math.max(8, Math.min(event.clientX, window.innerWidth - 220)),
            y: Math.max(8, Math.min(event.clientY, window.innerHeight - 48)),
        });
    };

    const startPhotoDrag = (
        event: DragEvent<HTMLElement>,
        photoId: string,
    ) => {
        setDraggedPhotoId(photoId);
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData(PHOTO_DRAG_TYPE, photoId);
        event.dataTransfer.setData("text/plain", photoId);
    };

    const endPhotoDrag = () => {
        setDraggedPhotoId(null);
        setDropTargetClusterId(null);
        setDraggingOver(false);
    };

    const computeScore = async (input: {
        rating: RankFeedback["rating"];
        text: string;
        source: "typed" | "voice";
    }) => {
        if (!rankingClusterId || !input.rating) return;
        const cluster = clusters.find((item) => item.id === rankingClusterId);
        if (!cluster) return;
        const restaurantName =
            cluster.selection?.name ?? cluster.match?.selected?.name ?? "";
        setScoreState({ status: "loading" });
        try {
            const runId = crypto.randomUUID();
            const response = await fetch("/api/score", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    runId,
                    stackId: cluster.id,
                    restaurantName,
                    rating: input.rating,
                    review: { text: input.text, source: input.source },
                    existingRatings: ratingsDictionary.entries,
                }),
            });
            const body = (await response.json()) as unknown;
            if (!response.ok) {
                const errorBody = body as { error?: string };
                throw new Error(errorBody.error ?? "Could not compute a score");
            }
            const result = scoreStackResponseSchema.parse(body);
            await saveScoreLog(runId, cluster.id, result);
            setScoreState({
                status: "ready",
                score: result.score.score,
                reasoning: result.score.reasoning,
            });
        } catch (error) {
            setScoreState({
                status: "error",
                error:
                    error instanceof Error ? error.message : "Could not compute a score",
            });
        }
    };

    const continueRanking = async (feedback: RankFeedback) => {
        if (!rankingClusterId || rankingLaunching) return;
        const cluster = clusters.find((item) => item.id === rankingClusterId);
        if (!cluster || !feedback.rating) return;
        setRankingLaunching(true);

        try {
            const selectedCandidate = cluster.match?.candidates.find(
                (candidate) => candidate.placeId === cluster.selection?.placeId,
            );
            const restaurantName =
                cluster.selection?.name ?? cluster.match?.selected?.name ?? "";
            const address =
                selectedCandidate?.address ?? clusterCity(cluster) ?? "";
            const takenAt = cluster.photos
                .map((photo) => photo.takenAt)
                .filter((value): value is number => value !== null)
                .sort((first, second) => first - second)[0] ?? Date.now();
            const date = new Date(takenAt);
            const visitDate = [
                date.getFullYear(),
                String(date.getMonth() + 1).padStart(2, "0"),
                String(date.getDate()).padStart(2, "0"),
            ].join("-");
            const formData = new FormData();
            formData.set("clusterId", cluster.id);
            formData.set("restaurantName", restaurantName);
            formData.set("address", address);
            formData.set("rating", feedback.rating);
            formData.set("category", cluster.category ?? "Restaurant");
            formData.set("description", feedback.description);
            formData.set(
                "photoDescriptions",
                JSON.stringify(feedback.photoDescriptions),
            );
            formData.set("visitDate", visitDate);
            formData.set(
                "existingRatings",
                JSON.stringify(ratingsDictionary.entries),
            );
            if (feedback.score !== null) {
                formData.set("computedScore", String(feedback.score));
            }
            for (const photo of cluster.photos) {
                formData.append("photos", photo.blob, photo.name);
            }
            const response = await fetch("/api/rank", {
                method: "POST",
                body: formData,
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not open ranking workspace"
                        : "Could not open ranking workspace",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : "Could not open ranking workspace",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const retryRanking = async (step: RankingStepId) => {
        if (!rankingProgress || rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank", {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    sessionId: rankingProgress.id,
                    step,
                    action: "retry",
                }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not retry this step"
                        : "Could not retry this step",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : "Could not retry this step",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const skipRankingStep = async (step: RankingStepId) => {
        if (!rankingProgress || rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank", {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    sessionId: rankingProgress.id,
                    step,
                    action: "skip",
                }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not skip this step"
                        : "Could not skip this step",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : "Could not skip this step",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const reopenRankingPhone = async () => {
        if (rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank/workspace", { method: "POST" });
            const result = (await response.json()) as { error?: string };
            if (!response.ok) {
                window.alert(result.error ?? "Could not reopen the ranking workspace");
            }
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : "Could not reopen the ranking workspace",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const toggleRankingPause = async () => {
        if (!rankingProgress || rankingLaunching) return;
        const action = rankingProgress.state === "paused" ? "resume" : "pause";
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank/control", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    sessionId: rankingProgress.id,
                    action,
                }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? `Could not ${action} ranking`
                        : `Could not ${action} ranking`,
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : `Could not ${action} ranking`,
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const skipRankingPhotos = async () => {
        if (!rankingProgress || rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank", {
                method: "PUT",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    sessionId: rankingProgress.id,
                    action: "skip",
                }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not skip photos"
                        : "Could not skip photos",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error ? error.message : "Could not skip photos",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const continueRankingPhotos = async () => {
        if (!rankingProgress || rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank", {
                method: "PUT",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    sessionId: rankingProgress.id,
                    action: "continue",
                }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not continue with added photos"
                        : "Could not continue with added photos",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error
                    ? error.message
                    : "Could not continue with added photos",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const hasPhotos = clusters.length > 0;
    const unlabeledClusters = clusters.filter((cluster) => !cluster.match);
    const rankingCluster = clusters.find(
        (cluster) => cluster.id === rankingClusterId,
    );

    const closeRanking = () => {
        setRankingClusterId(null);
        setRankingProgress(null);
        setScoreState({ status: "idle" });
    };

    const cancelRanking = async () => {
        if (!rankingProgress) {
            closeRanking();
            return;
        }
        if (rankingLaunching) return;
        setRankingLaunching(true);
        try {
            const response = await fetch("/api/rank", {
                method: "DELETE",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ sessionId: rankingProgress.id }),
            });
            const result = (await response.json()) as
                | RankingSessionStatus
                | { error?: string };
            if (!response.ok) {
                window.alert(
                    "error" in result
                        ? result.error ?? "Could not cancel ranking"
                        : "Could not cancel ranking",
                );
                return;
            }
            setRankingProgress(result as RankingSessionStatus);
        } catch (error) {
            window.alert(
                error instanceof Error ? error.message : "Could not cancel ranking",
            );
        } finally {
            setRankingLaunching(false);
        }
    };

    const finishRanking = () => {
        if (rankingClusterId) {
            setClusters((current) =>
                current.map((cluster) =>
                    cluster.id === rankingClusterId
                        ? { ...cluster, ranked: true }
                        : cluster,
                ),
            );
        }
        closeRanking();
    };

    return (
        <>
            <main
                className="relative min-h-screen bg-white px-6 pb-24 font-sans text-neutral-950"
                onDragEnter={(event) => {
                    event.preventDefault();
                    if (
                        !Array.from(event.dataTransfer.types).includes(
                            PHOTO_DRAG_TYPE,
                        )
                    ) {
                        setDraggingOver(true);
                    }
                }}
                onDragOver={(event) => event.preventDefault()}
                onDragLeave={(event) => {
                    if (event.currentTarget === event.target) {
                        setDraggingOver(false);
                    }
                }}
                onDrop={handlePageDrop}
            >
            <input
                ref={inputRef}
                className="sr-only"
                type="file"
                accept="image/*,.heic,.heif,.tif,.tiff,.zip,application/zip"
                multiple
                onChange={handleFileInput}
            />

            <OrganizerHeader
                hasPhotos={hasPhotos}
                processing={processing}
                labeling={labeling}
                mealCount={clusters.length}
                unlabeledCount={unlabeledClusters.length}
                onChooseFiles={chooseFiles}
                onClear={clearAll}
                onLabel={() => void labelClusters(unlabeledClusters)}
                onOpenRatingsDictionary={() => setRatingsDictionaryOpen(true)}
            />

            {hasPhotos ? (
                <section className="mx-auto w-full max-w-7xl pt-10" aria-live="polite">
                    <div className="mb-10 flex items-end justify-between gap-6 max-[680px]:flex-col max-[680px]:items-start">
                        <div>
                            <h1 className="m-0 font-serif text-[clamp(32px,3vw,40px)] font-bold leading-none tracking-[-0.02em] text-accent-dark">
                                {clusters.length} meal{clusters.length === 1 ? "" : "s"}
                            </h1>
                            {message ? (
                                <p className="mt-3 font-sans text-[15px] text-muted">
                                    {message}
                                </p>
                            ) : null}
                        </div>
                    </div>

                    <div className="grid grid-cols-1 items-stretch gap-6 md:grid-cols-2 lg:grid-cols-3">
                        {clusters.map((cluster) => (
                            <PhotoClusterCard
                                key={cluster.id}
                                cluster={cluster}
                                draggedPhotoId={draggedPhotoId}
                                isDropTarget={dropTargetClusterId === cluster.id}
                                onDropTargetChange={setDropTargetClusterId}
                                onMovePhoto={movePhoto}
                                onBringToFront={bringPhotoToFront}
                                onDeletePhoto={deletePhoto}
                                onStartDrag={startPhotoDrag}
                                onEndDrag={endPhotoDrag}
                                onOpenContextMenu={openPhotoContextMenu}
                                onSelectRestaurant={selectRestaurant}
                                onSelectCategory={selectCategory}
                                labeling={labeling}
                                onLabel={(clusterId) => {
                                    const cluster = clusters.find(
                                        (item) => item.id === clusterId,
                                    );
                                    if (cluster && !cluster.match) {
                                        void labelClusters([cluster]);
                                    }
                                }}
                                onOpenRanking={(clusterId) => {
                                    setRankingProgress(null);
                                    setScoreState({ status: "idle" });
                                    setRankingClusterId(clusterId);
                                }}
                            />
                        ))}
                    </div>
                </section>
            ) : (
                <EmptyUpload
                    processing={processing}
                    message={message}
                    onChooseFiles={chooseFiles}
                />
            )}

            {photoContextMenu ? (
                <PhotoContextMenu
                    menu={photoContextMenu}
                    onSplit={splitIntoSeparateMeal}
                />
            ) : null}

            {draggingOver ? (
                <div
                    className="pointer-events-none fixed inset-0 z-50 grid place-items-center bg-accent/80"
                    aria-hidden="true"
                >
                    <div className="flex flex-col items-center gap-3 rounded-[28px] bg-white px-16 py-14 text-center">
                        <span className="grid size-16 place-items-center rounded-full bg-accent-tint-2 text-2xl text-accent">
                            ↓
                        </span>
                        <span className="font-serif text-3xl font-bold text-accent-dark">
                            Drop to add photos
                        </span>
                        <span className="text-sm text-muted-2">
                            We&apos;ll sort them into meals by time and location
                        </span>
                    </div>
                </div>
            ) : null}
            </main>

            {ratingsDictionaryOpen ? (
                <RatingsDictionaryModal
                    entries={ratingsDictionary.entries}
                    syncedAt={ratingsDictionary.syncedAt}
                    onClose={() => setRatingsDictionaryOpen(false)}
                    onSave={(entries) => {
                        const syncedAt = new Date().toISOString();
                        setRatingsDictionary({ entries, syncedAt });
                        void saveRatingsDictionary({ entries, syncedAt }).catch(
                            (error) =>
                                console.error("Could not save ratings", error),
                        );
                    }}
                />
            ) : null}

            {rankingCluster ? (
                <RankingOverlay
                    restaurantName={
                        rankingCluster.selection?.name ??
                        rankingCluster.match?.selected?.name ??
                        "it"
                    }
                    photos={rankingCluster.photos}
                    launching={rankingLaunching}
                    progress={rankingProgress}
                    scoreState={scoreState}
                    onComputeScore={(input) => void computeScore(input)}
                    onCancel={closeRanking}
                    onCancelProcess={() => void cancelRanking()}
                    onContinue={(feedback) => void continueRanking(feedback)}
                    onReopenPhone={() => void reopenRankingPhone()}
                    onTogglePause={() => void toggleRankingPause()}
                    onRetry={(step) => void retryRanking(step)}
                    onSkipStep={(step) => void skipRankingStep(step)}
                    onContinuePhotos={() => void continueRankingPhotos()}
                    onSkipPhotos={() => void skipRankingPhotos()}
                    onFinished={finishRanking}
                />
            ) : null}
        </>
    );
}
