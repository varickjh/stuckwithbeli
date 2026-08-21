import type { PhotoCluster } from "./photo-types";
import type { ExistingRatings, LabelStackResponse, ScoreStackResponse } from "./stack-schema";

const DATABASE_NAME = "auto-beli";
const DATABASE_VERSION = 2;
const SESSION_STORE = "session";
const LOG_STORE = "label-logs";
const SCORE_LOG_STORE = "score-logs";
const CLUSTERS_KEY = "clusters";
const RATINGS_KEY = "ratingsDictionary";

export type RatingsDictionary = {
  entries: ExistingRatings;
  syncedAt: string;
};

function openDatabase() {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);

    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(SESSION_STORE)) {
        database.createObjectStore(SESSION_STORE);
      }
      if (!database.objectStoreNames.contains(LOG_STORE)) {
        database.createObjectStore(LOG_STORE, { keyPath: "id" });
      }
      if (!database.objectStoreNames.contains(SCORE_LOG_STORE)) {
        database.createObjectStore(SCORE_LOG_STORE, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function transactionDone(transaction: IDBTransaction) {
  return new Promise<void>((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

export async function loadClusters() {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(SESSION_STORE, "readonly");
    const request = transaction.objectStore(SESSION_STORE).get(CLUSTERS_KEY);
    const value = await new Promise<PhotoCluster[] | undefined>(
      (resolve, reject) => {
        request.onsuccess = () => resolve(request.result as PhotoCluster[]);
        request.onerror = () => reject(request.error);
      },
    );
    return value ?? [];
  } finally {
    database.close();
  }
}

export async function saveClusters(clusters: PhotoCluster[]) {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(SESSION_STORE, "readwrite");
    transaction.objectStore(SESSION_STORE).put(clusters, CLUSTERS_KEY);
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}

export async function saveLabelLog(
  runId: string,
  stackId: string,
  response: LabelStackResponse,
) {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(LOG_STORE, "readwrite");
    transaction.objectStore(LOG_STORE).put({
      id: `${runId}/${stackId}`,
      runId,
      stackId,
      savedAt: new Date().toISOString(),
      response,
    });
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}

export async function loadRatingsDictionary() {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(SESSION_STORE, "readonly");
    const request = transaction.objectStore(SESSION_STORE).get(RATINGS_KEY);
    const value = await new Promise<RatingsDictionary | undefined>(
      (resolve, reject) => {
        request.onsuccess = () => resolve(request.result as RatingsDictionary);
        request.onerror = () => reject(request.error);
      },
    );
    return value ?? null;
  } finally {
    database.close();
  }
}

export async function saveRatingsDictionary(dictionary: RatingsDictionary) {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(SESSION_STORE, "readwrite");
    transaction.objectStore(SESSION_STORE).put(dictionary, RATINGS_KEY);
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}

export async function saveScoreLog(
  runId: string,
  stackId: string,
  response: ScoreStackResponse,
) {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(SCORE_LOG_STORE, "readwrite");
    transaction.objectStore(SCORE_LOG_STORE).put({
      id: `${runId}/${stackId}`,
      runId,
      stackId,
      savedAt: new Date().toISOString(),
      response,
    });
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}

export async function clearBrowserData() {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(
      [SESSION_STORE, LOG_STORE, SCORE_LOG_STORE],
      "readwrite",
    );
    transaction.objectStore(SESSION_STORE).clear();
    transaction.objectStore(LOG_STORE).clear();
    transaction.objectStore(SCORE_LOG_STORE).clear();
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}
