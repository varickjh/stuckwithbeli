import type { DragEvent, KeyboardEvent, MouseEvent } from "react";
import { FaXmark } from "react-icons/fa6";
import SquareLoader from "react-spinners/SquareLoader";

import { clusterCity, formatClusterDate } from "../lib/photo-processing";
import { PHOTO_DRAG_TYPE, type PhotoCluster } from "../lib/photo-types";
import type { MealCategory, RestaurantSelection } from "../lib/stack-schema";
import { MealCategoryMenu } from "./meal-category-menu";
import { PhotoImage } from "./photo-image";
import { PlaceCombobox } from "./place-combobox";

const STACK_ANGLES = [0, -6, 7] as const;
const STACK_OFFSETS = [
    { x: 0, y: 0 },
    { x: -5, y: 2 },
    { x: 4, y: -4 },
] as const;

type PhotoClusterCardProps = {
    cluster: PhotoCluster;
    draggedPhotoId: string | null;
    isDropTarget: boolean;
    onDropTargetChange: (clusterId: string | null) => void;
    onMovePhoto: (photoId: string, targetClusterId: string) => void;
    onBringToFront: (clusterId: string, photoId: string) => void;
    onDeletePhoto: (photoId: string) => void;
    onStartDrag: (event: DragEvent<HTMLElement>, photoId: string) => void;
    onEndDrag: () => void;
    onOpenContextMenu: (
        event: MouseEvent<HTMLElement>,
        clusterId: string,
        photoId: string,
    ) => void;
    onSelectRestaurant: (
        clusterId: string,
        selection: RestaurantSelection,
    ) => void;
    onSelectCategory: (clusterId: string, category: MealCategory) => void;
    labeling: boolean;
    onLabel: (clusterId: string) => void;
    onOpenRanking: (clusterId: string) => void;
};

function isPhotoDrag(event: DragEvent<HTMLElement>) {
    return Array.from(event.dataTransfer.types).includes(PHOTO_DRAG_TYPE);
}

export function PhotoClusterCard({
    cluster,
    draggedPhotoId,
    isDropTarget,
    onDropTargetChange,
    onMovePhoto,
    onBringToFront,
    onDeletePhoto,
    onStartDrag,
    onEndDrag,
    onOpenContextMenu,
    onSelectRestaurant,
    onSelectCategory,
    labeling,
    onLabel,
    onOpenRanking,
}: PhotoClusterCardProps) {
    const stackPhotos = cluster.photos.slice(0, 3);
    const candidates = cluster.match?.candidates ?? [];
    const selectedCandidate = candidates.find(
        (candidate) => candidate.placeId === cluster.selection?.placeId,
    );
    const address = selectedCandidate?.address ?? clusterCity(cluster);
    const canLabel = !cluster.match && !labeling;

    const handlePreviewKeyDown = (
        event: KeyboardEvent<HTMLDivElement>,
        photoId: string,
    ) => {
        if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            onBringToFront(cluster.id, photoId);
        }
    };

    return (
        <article
            className={`group/card relative flex h-full min-w-0 flex-col gap-5 overflow-hidden rounded-[20px] p-6 text-ink transition-colors duration-200 ${isDropTarget ? "bg-accent-tint-2" : cluster.ranked ? "bg-card opacity-75 grayscale-[50%]" : cluster.labelStatus === "error" ? "bg-disliked-tint" : "bg-card hover:bg-card-2"}`}
            title={cluster.labelError ?? undefined}
            onDragEnter={(event) => {
                if (!isPhotoDrag(event)) return;
                event.preventDefault();
                event.stopPropagation();
                onDropTargetChange(cluster.id);
            }}
            onDragOver={(event) => {
                if (!isPhotoDrag(event)) return;
                event.preventDefault();
                event.stopPropagation();
                event.dataTransfer.dropEffect = "move";
                onDropTargetChange(cluster.id);
            }}
            onDragLeave={(event) => {
                if (
                    !event.relatedTarget ||
                    !event.currentTarget.contains(event.relatedTarget as Node)
                ) {
                    onDropTargetChange(null);
                }
            }}
            onDrop={(event) => {
                if (!isPhotoDrag(event)) return;
                event.preventDefault();
                event.stopPropagation();
                const photoId = event.dataTransfer.getData(PHOTO_DRAG_TYPE);
                if (photoId) onMovePhoto(photoId, cluster.id);
            }}
        >
            <p className="text-sm text-muted text-center -mb-4">
                {formatClusterDate(cluster)}
            </p>

            <div
                className={`group relative mx-auto aspect-square w-full p-8 rounded-sm`}
            >

                <div
                    className="w-full h-full relative hover:scale-102 transition-transform duration-200"
                >
                    {stackPhotos.map((photo, index) => (
                        <span
                            className={`absolute inset-0 block origin-center overflow-hidden bg-neutral-200 transition-transform duration-200 ${index === 0 ? "cursor-grab active:cursor-grabbing" : ""}`}
                            key={photo.id}
                            draggable={index === 0}
                            onDragStart={
                                index === 0
                                    ? (event) => onStartDrag(event, photo.id)
                                    : undefined
                            }
                            onDragEnd={index === 0 ? onEndDrag : undefined}
                            onContextMenu={
                                index === 0
                                    ? (event) =>
                                        onOpenContextMenu(
                                            event,
                                            cluster.id,
                                            photo.id,
                                        )
                                    : undefined
                            }
                            aria-label={
                                index === 0
                                    ? `Drag ${photo.name} to another cluster`
                                    : undefined
                            }
                            style={{
                                zIndex: stackPhotos.length - index,
                                filter: `grayscale(${index * 50}%)`,
                                transform:
                                    stackPhotos.length === 1
                                        ? "none"
                                        : `translate(${STACK_OFFSETS[index].x}px, ${STACK_OFFSETS[index].y}px) rotate(${STACK_ANGLES[index]}deg)`,
                            }}
                        >
                            <PhotoImage photo={photo} alt="" />
                            {index === 0 ? (
                                <button
                                    className="rounded-full absolute right-2 top-2 z-20 grid size-8 place-items-center bg-white text-ink opacity-0 transition-opacity hover:opacity-80 focus:opacity-100 group-hover:opacity-100"
                                    type="button"
                                    draggable={false}
                                    aria-label={`Delete ${photo.name}`}
                                    onPointerDown={(event) =>
                                        event.stopPropagation()
                                    }
                                    onClick={(event) => {
                                        event.stopPropagation();
                                        onDeletePhoto(photo.id);
                                    }}
                                >
                                    <FaXmark
                                        className="size-4"
                                        aria-hidden="true"
                                    />
                                </button>
                            ) : null}
                        </span>
                    ))}</div>
            </div>

            {cluster.photos.length > 1 ? (
                <div
                    className="flex flex-wrap gap-2 mt-4"
                    aria-label="Photos in this cluster"
                >
                    {cluster.photos.map((photo) => (
                        <div
                            className="group/preview relative size-14 cursor-grab overflow-hidden bg-neutral-300 opacity-80 transition-[opacity,transform] hover:-translate-y-1 hover:opacity-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-950 active:cursor-grabbing"
                            key={photo.id}
                            draggable
                            role="button"
                            tabIndex={0}
                            aria-label={`Bring ${photo.name} to the front of this stack`}
                            onClick={() => onBringToFront(cluster.id, photo.id)}
                            onKeyDown={(event) =>
                                handlePreviewKeyDown(event, photo.id)
                            }
                            onDragStart={(event) =>
                                onStartDrag(event, photo.id)
                            }
                            onDragEnd={onEndDrag}
                            onContextMenu={(event) =>
                                onOpenContextMenu(event, cluster.id, photo.id)
                            }
                            title={`Drag ${photo.name} to another stack`}
                        >
                            <PhotoImage photo={photo} alt={photo.name} />
                            <button
                                className={
                                    draggedPhotoId
                                        ? "hidden"
                                        : "rounded-full absolute right-1 top-1 z-20 grid size-6 place-items-center bg-white text-ink opacity-0 transition-opacity hover:opacity-80 focus:opacity-100 group-hover/preview:opacity-100"
                                }
                                type="button"
                                draggable={false}
                                aria-label={`Delete ${photo.name}`}
                                onPointerDown={(event) =>
                                    event.stopPropagation()
                                }
                                onClick={(event) => {
                                    event.stopPropagation();
                                    onDeletePhoto(photo.id);
                                }}
                            >
                                <FaXmark
                                    className="size-3"
                                    aria-hidden="true"
                                />
                            </button>
                        </div>
                    ))}
                </div>
            ) : null}



            <div className="flex min-w-0 flex-col gap-1">
                {cluster.selection || candidates.length ? (
                    <PlaceCombobox
                        candidates={candidates}
                        selection={cluster.selection}
                        onSelect={(selection) =>
                            onSelectRestaurant(cluster.id, selection)
                        }
                    />
                ) : null}
                {cluster.labelStatus === "error" ? (
                    <p className="m-0 text-sm leading-relaxed text-error">
                        {cluster.labelError ?? "Couldn't match — try again"}
                    </p>
                ) : address ? (
                    <p className="m-0 text-sm leading-relaxed text-muted-2">
                        {address}
                    </p>
                ) : null}

            </div>



            {cluster.category ? (
                <MealCategoryMenu
                    value={cluster.category}
                    onChange={(category) =>
                        onSelectCategory(cluster.id, category)
                    }
                />
            ) : null}

            <div className="flex-1" />

            {canLabel ? (
                <button
                    className={
                        cluster.labelStatus === "error"
                            ? "rounded-full bg-disliked px-3 py-2.5 text-sm font-bold text-error-dark transition-colors hover:opacity-85"
                            : "rounded-full bg-accent px-3 py-2.5 text-sm font-bold text-white transition-colors hover:bg-accent/85"
                    }
                    type="button"
                    onClick={() => onLabel(cluster.id)}
                >
                    {cluster.labelStatus === "error" ? "Retry" : "Label"}
                </button>
            ) : null}

            {cluster.match ? (
                <button
                    className={
                        cluster.ranked
                            ? "rounded-full bg-skeleton px-3 py-2.5 text-sm font-bold text-muted-2"
                            : "rounded-full bg-accent px-3 py-2.5 text-sm font-bold text-white transition-colors hover:bg-accent/85"
                    }
                    type="button"
                    disabled={cluster.ranked}
                    onClick={() => onOpenRanking(cluster.id)}
                >
                    {cluster.ranked ? "✓ Ranked" : "Rank"}
                </button>
            ) : null}

            {cluster.labelStatus === "matching" ? (
                <div
                    className="absolute inset-0 z-[110] grid place-items-center bg-card/90"
                    aria-label="Matching location"
                >
                    <SquareLoader
                        color="var(--color-accent)"
                        size={48}
                        speedMultiplier={1.15}
                    />
                </div>
            ) : null}

            {cluster.labelStatus === "queued" ? (
                <div
                    className="absolute inset-0 z-[110] grid place-items-center bg-card/90"
                    aria-label="Matching location"
                >
                    <SquareLoader
                        color="var(--color-neutral-700)"
                        size={48}
                        speedMultiplier={1.15}
                    />
                </div>
            ) : null}
        </article>
    );
}
