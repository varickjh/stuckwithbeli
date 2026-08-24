import JSZip from "jszip";

import type { Photo, PhotoCluster } from "./photo-types";

const MAX_DISTANCE_METERS = 50;
const MAX_TIME_DIFFERENCE_MS = 4 * 60 * 60 * 1000;

const imageExtensions = new Set([
  "avif",
  "bmp",
  "gif",
  "heic",
  "heif",
  "jpeg",
  "jpg",
  "png",
  "tif",
  "tiff",
  "webp",
]);

const browserPreviewExtensions = new Set([
  "avif",
  "bmp",
  "gif",
  "jpeg",
  "jpg",
  "png",
  "webp",
]);

type CandidateFile = {
  blob: Blob;
  name: string;
  path: string;
  lastModified: number | null;
};

export function extensionFor(name: string) {
  return name.split(".").pop()?.toLowerCase() ?? "";
}

function isImage(name: string) {
  return imageExtensions.has(extensionFor(name));
}

function isZip(name: string) {
  return extensionFor(name) === "zip";
}

async function unpackBlob(
  blob: Blob,
  name: string,
  path: string,
  lastModified: number | null,
): Promise<CandidateFile[]> {
  if (!isZip(name)) {
    return isImage(name) ? [{ blob, name, path, lastModified }] : [];
  }

  const archive = await JSZip.loadAsync(blob);
  const collected: CandidateFile[] = [];

  for (const entry of Object.values(archive.files)) {
    if (entry.dir) continue;

    const nestedBlob = await entry.async("blob");
    const nestedPath = `${path.replace(/\.zip$/i, "")}/${entry.name}`;
    if (isZip(entry.name)) {
      collected.push(
        ...(await unpackBlob(
          nestedBlob,
          entry.name,
          nestedPath,
          entry.date.getTime(),
        )),
      );
    } else if (isImage(entry.name)) {
      collected.push({
        blob: nestedBlob,
        name: entry.name.split("/").pop() ?? entry.name,
        path: nestedPath,
        lastModified: entry.date.getTime(),
      });
    }
  }

  return collected;
}

export async function checksumBlob(blob: Blob) {
  const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function readPhoto(
  candidate: CandidateFile,
  checksum: string,
): Promise<Photo> {
  const formData = new FormData();
  formData.set("file", candidate.blob, candidate.name);
  formData.set("path", candidate.path);
  if (candidate.lastModified !== null) {
    formData.set("lastModified", String(candidate.lastModified));
  }

  const response = await fetch("/api/photos/process", {
    method: "POST",
    body: formData,
  });
  const result = (await response.json()) as
    | {
        data: string;
        latitude: number | null;
        longitude: number | null;
        mediaType: string;
        name: string;
        path: string;
        size: number;
        takenAt: number | null;
        url: string;
      }
    | { error?: string };

  if (!response.ok || !("data" in result)) {
    const message =
      "error" in result
        ? result.error ?? "Photo processing failed"
        : "Photo processing failed";
    throw new Error(message);
  }

  const binary = atob(result.data);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  const displayBlob = new Blob([bytes], { type: result.mediaType });

  return {
    id: crypto.randomUUID(),
    checksum,
    name: result.name,
    path: result.path,
    // A stable server URL (not a blob: URL) -- works across tabs, browsers,
    // and reloads without needing to be reconstructed from stored bytes.
    url: result.url,
    blob: displayBlob,
    mediaType: result.mediaType,
    size: result.size,
    previewable: browserPreviewExtensions.has(extensionFor(result.name)),
    takenAt: result.takenAt,
    latitude: result.latitude,
    longitude: result.longitude,
  };
}

function distanceInMeters(a: Photo, b: Photo) {
  if (
    a.latitude === null ||
    a.longitude === null ||
    b.latitude === null ||
    b.longitude === null
  ) {
    return null;
  }

  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const latDelta = radians(b.latitude - a.latitude);
  const lonDelta = radians(b.longitude - a.longitude);
  const startLat = radians(a.latitude);
  const endLat = radians(b.latitude);
  const haversine =
    Math.sin(latDelta / 2) ** 2 +
    Math.cos(startLat) * Math.cos(endLat) * Math.sin(lonDelta / 2) ** 2;

  return (
    6_371_000 *
    2 *
    Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine))
  );
}

function photosBelongTogether(a: Photo, b: Photo) {
  const timeClose =
    a.takenAt !== null &&
    b.takenAt !== null &&
    Math.abs(a.takenAt - b.takenAt) <= MAX_TIME_DIFFERENCE_MS;
  if (!timeClose) return false;

  const distance = distanceInMeters(a, b);
  return distance !== null && distance <= MAX_DISTANCE_METERS;
}

export function clusterPhotos(photos: Photo[]) {
  const sorted = [...photos].sort(
    (a, b) =>
      (a.takenAt ?? Number.MAX_SAFE_INTEGER) -
      (b.takenAt ?? Number.MAX_SAFE_INTEGER),
  );
  const clusters: PhotoCluster[] = [];

  for (const photo of sorted) {
    const existing = clusters.find((cluster) =>
      cluster.photos.some((member) => photosBelongTogether(member, photo)),
    );
    if (existing) existing.photos.push(photo);
    else {
      clusters.push({
        id: crypto.randomUUID(),
        photos: [photo],
        ranked: false,
        labelStatus: "ready",
        placesSearch: null,
        match: null,
        category: null,
        selection: null,
        labelError: null,
      });
    }
  }

  return clusters;
}

export function addPhotosToClusters(
  currentClusters: PhotoCluster[],
  newPhotos: Photo[],
) {
  const clusters = currentClusters.map((cluster) => ({
    ...cluster,
    photos: [...cluster.photos],
  }));

  for (const photo of newPhotos) {
    const existing = clusters.find((cluster) =>
      cluster.photos.some((member) => photosBelongTogether(member, photo)),
    );

    if (existing) {
      existing.photos.push(photo);
      existing.photos.sort(
        (a, b) =>
          (a.takenAt ?? Number.MAX_SAFE_INTEGER) -
          (b.takenAt ?? Number.MAX_SAFE_INTEGER),
      );
    } else {
      clusters.push({
        id: crypto.randomUUID(),
        photos: [photo],
        ranked: false,
        labelStatus: "ready",
        placesSearch: null,
        match: null,
        category: null,
        selection: null,
        labelError: null,
      });
    }
  }

  return clusters;
}

export function clusterCoordinate(cluster: PhotoCluster) {
  const coordinates = cluster.photos.flatMap((photo) =>
    photo.latitude !== null && photo.longitude !== null
      ? [{ latitude: photo.latitude, longitude: photo.longitude }]
      : [],
  );
  if (!coordinates.length) return null;

  const middle = Math.floor(coordinates.length / 2);
  const latitudes = coordinates
    .map(({ latitude }) => latitude)
    .sort((a, b) => a - b);
  const longitudes = coordinates
    .map(({ longitude }) => longitude)
    .sort((a, b) => a - b);

  return {
    latitude: latitudes[middle],
    longitude: longitudes[middle],
  };
}

export async function processFiles(
  files: File[],
  existingChecksums: Iterable<string> = [],
) {
  const candidates = (
    await Promise.all(
      files.map((file) =>
        unpackBlob(
          file,
          file.name,
          file.webkitRelativePath || file.name,
          file.lastModified,
        ),
      ),
    )
  ).flat();

  const checksums = new Set(existingChecksums);
  const uniqueCandidates: Array<CandidateFile & { checksum: string }> = [];

  for (const candidate of candidates) {
    const checksum = await checksumBlob(candidate.blob);
    if (checksums.has(checksum)) continue;
    checksums.add(checksum);
    uniqueCandidates.push({ ...candidate, checksum });
  }

  return Promise.all(
    uniqueCandidates.map(({ checksum, ...candidate }) =>
      readPhoto(candidate, checksum),
    ),
  );
}

export function formatClusterDate(cluster: PhotoCluster) {
  const timestamp = cluster.photos.find((photo) => photo.takenAt)?.takenAt;
  if (!timestamp) return "Date unavailable";

  return new Intl.DateTimeFormat(undefined, {
    month: "numeric",
    day: "numeric",
    year: "numeric",
  }).format(timestamp);
}

const CITY_COMPONENT_TYPES = [
  "locality",
  "postal_town",
  "sublocality",
  "administrative_area_level_2",
  "administrative_area_level_1",
] as const;

export function clusterCity(cluster: PhotoCluster) {
  const candidates = cluster.match?.candidates ?? [];
  const selectedPlace =
    candidates.find(
      (candidate) => candidate.placeId === cluster.selection?.placeId,
    )?.place ?? candidates[0]?.place;
  const components = selectedPlace?.addressComponents ?? [];

  for (const type of CITY_COMPONENT_TYPES) {
    const city = components.find((component) =>
      component.types?.includes(type),
    )?.longText;
    if (city) return city;
  }

  return null;
}

// Photos loaded from another browser/session only carry a stable server url,
// not the in-memory Blob from this tab's own upload -- fetch it on demand.
export async function getPhotoBlob(photo: Photo): Promise<Blob> {
  if (photo.blob) return photo.blob;
  const response = await fetch(photo.url);
  if (!response.ok) throw new Error(`Could not load photo ${photo.name}`);
  return response.blob();
}
