import type { ChildProcess } from "node:child_process";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

import { getAutomationBinary } from "./beli-automation";

export type RatingsExportStatus = {
    id: string;
    state: "running" | "complete" | "error" | "cancelled";
    message: string | null;
    entries: Record<string, number> | null;
    error: string | null;
};

type SessionRecord = RatingsExportStatus & {
    process: ChildProcess | null;
    workDirectory: string;
    outputPath: string;
};

const globalSessions = globalThis as typeof globalThis & {
    autoBeliRatingsExportSessions?: Map<string, SessionRecord>;
};

const sessions =
    globalSessions.autoBeliRatingsExportSessions ?? new Map<string, SessionRecord>();
globalSessions.autoBeliRatingsExportSessions = sessions;

function toStatus(session: SessionRecord): RatingsExportStatus {
    return {
        id: session.id,
        state: session.state,
        message: session.message,
        entries: session.entries,
        error: session.error,
    };
}

export async function startRatingsExport() {
    if (process.platform !== "darwin") {
        throw new Error("Beli automation requires macOS.");
    }

    const binary = await getAutomationBinary();
    const id = randomUUID();
    const workDirectory = await mkdtemp(join(tmpdir(), "auto-beli-ratings-export-"));
    const outputPath = join(workDirectory, "ratings.json");

    const session: SessionRecord = {
        id,
        state: "running",
        message: null,
        entries: null,
        error: null,
        process: null,
        workDirectory,
        outputPath,
    };
    sessions.set(id, session);

    const child = spawn(binary, ["--export-ratings", outputPath], {
        stdio: ["ignore", "pipe", "pipe"],
    });
    session.process = child;
    let stderr = "";

    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
        stderr = `${stderr}${chunk}`.slice(-4_000);
    });

    if (child.stdout) {
        const lines = createInterface({ input: child.stdout });
        lines.on("line", (line) => {
            let event: { type?: string; message?: string; count?: number };
            try {
                event = JSON.parse(line) as typeof event;
            } catch {
                return;
            }
            const current = sessions.get(id);
            if (!current || current.state !== "running") return;
            if (event.type === "diagnostic") {
                current.message = event.message ?? current.message;
            } else if (event.type === "error") {
                current.state = "error";
                current.error = event.message ?? "Ratings export failed.";
            }
        });
    }

    child.on("close", (code) => {
        const current = sessions.get(id);
        if (!current) return;
        current.process = null;
        if (current.state === "cancelled") return;
        if (code !== 0 && current.state !== "error") {
            current.state = "error";
            current.error = stderr.trim() || "Ratings export stopped unexpectedly.";
            return;
        }
        if (current.state === "error") return;
        void readFile(current.outputPath, "utf8")
            .then((contents) => {
                current.entries = JSON.parse(contents) as Record<string, number>;
                current.state = "complete";
            })
            .catch((error) => {
                current.state = "error";
                current.error =
                    error instanceof Error
                        ? error.message
                        : "Could not read the exported ratings.";
            });
    });

    return toStatus(session);
}

export function getRatingsExportStatus(id: string) {
    const session = sessions.get(id);
    return session ? toStatus(session) : null;
}

export async function cancelRatingsExport(id: string) {
    const session = sessions.get(id);
    if (!session) return null;
    session.state = "cancelled";
    session.process?.kill();
    await rm(session.workDirectory, { recursive: true, force: true });
    return toStatus(session);
}
