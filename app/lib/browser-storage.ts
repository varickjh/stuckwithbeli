import type { LabelStackResponse, ScoreStackResponse } from "./stack-schema";

const DATABASE_NAME = "auto-beli";
const DATABASE_VERSION = 2;
const SESSION_STORE = "session";
const LOG_STORE = "label-logs";
const SCORE_LOG_STORE = "score-logs";

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
