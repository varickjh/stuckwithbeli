import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { PhotoCluster } from "./photo-types";
import type { ExistingRatings } from "./stack-schema";

export const DATA_DIR = join(process.cwd(), "data");
export const PHOTOS_DIR = join(DATA_DIR, "photos");
const STORE_FILE = join(DATA_DIR, "store.json");

export type StoredRatingsDictionary = {
  entries: ExistingRatings;
  syncedAt: string;
};

type Store = {
  clusters: PhotoCluster[];
  ratingsDictionary: StoredRatingsDictionary | null;
};

const EMPTY_STORE: Store = { clusters: [], ratingsDictionary: null };

// Serializes writes so two near-simultaneous saves (e.g. two open tabs)
// can't interleave and corrupt the file -- each write waits for the
// previous one to finish.
let writeQueue: Promise<unknown> = Promise.resolve();

export async function readStore(): Promise<Store> {
  try {
    const raw = await readFile(STORE_FILE, "utf8");
    const parsed = JSON.parse(raw) as Partial<Store>;
    return {
      clusters: Array.isArray(parsed.clusters) ? parsed.clusters : [],
      ratingsDictionary: parsed.ratingsDictionary ?? null,
    };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return EMPTY_STORE;
    throw error;
  }
}

async function writeStoreNow(patch: Partial<Store>): Promise<Store> {
  const current = await readStore();
  const next: Store = { ...current, ...patch };
  await mkdir(DATA_DIR, { recursive: true });
  const tempFile = `${STORE_FILE}.${crypto.randomUUID()}.tmp`;
  await writeFile(tempFile, JSON.stringify(next));
  await rename(tempFile, STORE_FILE);
  return next;
}

export function writeStore(patch: Partial<Store>): Promise<Store> {
  const result = writeQueue.then(() => writeStoreNow(patch));
  // Keep the queue alive even if this write fails, so later writes still run.
  writeQueue = result.catch(() => undefined);
  return result;
}

export async function ensurePhotosDir() {
  await mkdir(PHOTOS_DIR, { recursive: true });
}
