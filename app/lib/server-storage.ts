import type { PhotoCluster } from "./photo-types";
import type { ExistingRatings } from "./stack-schema";

export type RatingsDictionary = {
  entries: ExistingRatings;
  syncedAt: string;
};

export async function loadClusters(): Promise<PhotoCluster[]> {
  const response = await fetch("/api/clusters");
  if (!response.ok) return [];
  const body = (await response.json()) as { clusters?: PhotoCluster[] };
  return body.clusters ?? [];
}

export async function saveClusters(clusters: PhotoCluster[]) {
  const response = await fetch("/api/clusters", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    // blob isn't JSON-serializable and photos are already stored server-side
    // as files -- strip it before sending (JSON.stringify drops undefined keys).
    body: JSON.stringify({
      clusters: clusters.map((cluster) => ({
        ...cluster,
        photos: cluster.photos.map((photo) => ({ ...photo, blob: undefined })),
      })),
    }),
  });
  if (!response.ok) throw new Error("Could not save photo progress");
}

export async function loadRatingsDictionary(): Promise<RatingsDictionary | null> {
  const response = await fetch("/api/ratings-dictionary");
  if (!response.ok) return null;
  const body = (await response.json()) as {
    ratingsDictionary?: RatingsDictionary | null;
  };
  return body.ratingsDictionary ?? null;
}

export async function saveRatingsDictionary(dictionary: RatingsDictionary) {
  const response = await fetch("/api/ratings-dictionary", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ratingsDictionary: dictionary }),
  });
  if (!response.ok) throw new Error("Could not save ratings");
}

export async function clearServerData() {
  await Promise.all([
    saveClusters([]),
    fetch("/api/ratings-dictionary", { method: "DELETE" }),
  ]);
}
