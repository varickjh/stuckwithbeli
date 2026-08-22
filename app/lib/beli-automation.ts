import type { ChildProcess } from "node:child_process";
import { execFile, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";

import {
    RANKING_STEPS,
    type RankingSessionStatus,
    type RankingStepId,
} from "./ranking-types";

const execFileAsync = promisify(execFile);
const sourcePath = resolve(process.cwd(), "scripts/beli-automation.swift");
const moduleCachePath = join(tmpdir(), "auto-beli-swift-module-cache");
const cleanupDelay = 4 * 60 * 60 * 1_000;

type StartAutomationInput = {
    clusterId: string;
    restaurantName: string;
    address: string;
    rating: "liked" | "fine" | "disliked";
    category: string;
    description: string;
    photoDescriptions: string[];
    visitDate: string;
    existingRatings: Record<string, number>;
    computedScore: number | null;
    photos: File[];
};

type SessionRecord = RankingSessionStatus & {
    binary: string;
    configPath: string;
    workDirectory: string;
    process: ChildProcess | null;
    runVersion: number;
    cleanupTimer: NodeJS.Timeout | null;
};

const globalSessions = globalThis as typeof globalThis & {
    autoBeliRankingSessions?: Map<string, SessionRecord>;
    autoBeliCompilePromise?: Promise<string>;
};

const sessions =
    globalSessions.autoBeliRankingSessions ?? new Map<string, SessionRecord>();
globalSessions.autoBeliRankingSessions = sessions;

function freshSteps(startStep: RankingStepId): RankingSessionStatus["steps"] {
    const startIndex = RANKING_STEPS.findIndex((step) => step.id === startStep);
    return Object.fromEntries(
        RANKING_STEPS.map((step, index) => [
            step.id,
            index < startIndex
                ? "complete"
                : index === startIndex
                  ? "active"
                  : "pending",
        ]),
    ) as RankingSessionStatus["steps"];
}

async function binaryPath() {
    const source = await readFile(sourcePath);
    const sourceHash = createHash("sha256").update(source).digest("hex").slice(0, 16);
    return join(tmpdir(), `auto-beli-automation-${sourceHash}`);
}

async function compileAutomation() {
    const outputPath = await binaryPath();
    try {
        await stat(outputPath);
        return outputPath;
    } catch {
        await mkdir(moduleCachePath, { recursive: true });
    }

    await execFileAsync(
        "/usr/bin/swiftc",
        [
            "-swift-version",
            "5",
            "-parse-as-library",
            "-module-cache-path",
            moduleCachePath,
            sourcePath,
            "-o",
            outputPath,
            "-framework",
            "ScreenCaptureKit",
            "-framework",
            "Vision",
            "-framework",
            "AppKit",
        ],
        { timeout: 120_000, maxBuffer: 4 * 1024 * 1024 },
    );
    return outputPath;
}

export async function getAutomationBinary() {
    globalSessions.autoBeliCompilePromise ??= compileAutomation().finally(() => {
        globalSessions.autoBeliCompilePromise = undefined;
    });
    return globalSessions.autoBeliCompilePromise;
}

function currentSession(sessionId: string, runVersion: number) {
    const session = sessions.get(sessionId);
    return session?.runVersion === runVersion ? session : null;
}

function scheduleCleanup(session: SessionRecord) {
    if (session.cleanupTimer) clearTimeout(session.cleanupTimer);
    session.cleanupTimer = setTimeout(() => {
        if (session.process) return;
        sessions.delete(session.id);
        void rm(session.workDirectory, { recursive: true, force: true });
    }, cleanupDelay);
    session.cleanupTimer.unref();
}

function launchSession(
    session: SessionRecord,
    startStep: RankingStepId | "skip_photos" | "continue_photos",
) {
    session.runVersion += 1;
    const runVersion = session.runVersion;
    const argumentsList =
        startStep === "skip_photos"
            ? ["--config", session.configPath, "--skip-photos"]
            : startStep === "continue_photos"
              ? ["--config", session.configPath, "--continue-photos"]
              : ["--config", session.configPath, "--start-step", startStep];
    const child = spawn(
        session.binary,
        argumentsList,
        { stdio: ["ignore", "pipe", "pipe"] },
    );
    session.process = child;
    let stderr = "";

    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
        stderr = `${stderr}${chunk}`.slice(-4_000);
    });

    if (child.stdout) {
        const lines = createInterface({ input: child.stdout });
        lines.on("line", (line) => {
            let event: {
                type?: string;
                step?: RankingStepId;
                message?: string;
                code?: string;
            };
            try {
                event = JSON.parse(line) as typeof event;
            } catch {
                return;
            }

            const current = currentSession(session.id, runVersion);
            if (!current) return;
            if (
                event.type === "progress" &&
                event.step &&
                event.step in current.steps
            ) {
                current.steps[event.step] = "active";
            } else if (
                event.type === "finished" &&
                event.step &&
                event.step in current.steps
            ) {
                current.steps[event.step] = "complete";
            } else if (event.type === "complete") {
                current.state = "complete";
                current.celebrating = true;
                current.error = null;
                current.recovery = null;
                for (const step of RANKING_STEPS) current.steps[step.id] = "complete";
            } else if (event.type === "celebrate") {
                current.celebrating = true;
            } else if (event.type === "error") {
                current.state = "error";
                current.celebrating = false;
                current.error = event.message ?? "Beli automation failed.";
                current.recovery =
                    event.code === "photos_not_found" ? "photos_not_found" : null;
            } else if (event.type === "diagnostic") {
                console.info(
                    `[beli-automation:${session.id}] ${event.message ?? ""}`,
                );
            } else if (event.type === "duel" && event.message) {
                current.duelLog.push({ message: event.message });
            }
        });
    }

    child.on("error", (error) => {
        const current = currentSession(session.id, runVersion);
        if (!current) return;
        current.state = "error";
        current.celebrating = false;
        current.error = error.message;
        current.recovery = null;
    });
    child.on("close", (code) => {
        const current = currentSession(session.id, runVersion);
        if (!current) return;
        current.process = null;
        if (code !== 0 && current.state !== "error") {
            current.state = "error";
            current.celebrating = false;
            current.error = stderr.trim() || "Beli automation stopped unexpectedly.";
            current.recovery = null;
        }
        scheduleCleanup(current);
    });
}

async function stopSessionProcess(session: SessionRecord) {
    const child = session.process;
    if (!child) return;
    session.runVersion += 1;
    session.process = null;
    await new Promise<void>((resolveStop) => {
        const timeout = setTimeout(resolveStop, 2_000);
        timeout.unref();
        child.once("close", () => {
            clearTimeout(timeout);
            resolveStop();
        });
        child.kill("SIGCONT");
        if (!child.kill()) {
            clearTimeout(timeout);
            resolveStop();
        }
    });
}

export async function startBeliAutomation(input: StartAutomationInput) {
    if (process.platform !== "darwin") {
        throw new Error("Beli automation requires macOS.");
    }

    const binary = await getAutomationBinary();
    const sessionId = randomUUID();
    const workDirectory = await mkdtemp(join(tmpdir(), "auto-beli-ranking-"));
    const photoPaths = await Promise.all(
        input.photos.map(async (photo, index) => {
            const extension = extname(photo.name) || ".jpg";
            const path = join(workDirectory, `photo-${index}${extension}`);
            await writeFile(path, Buffer.from(await photo.arrayBuffer()));
            return path;
        }),
    );
    const configPath = join(workDirectory, "config.json");
    await writeFile(
        configPath,
        JSON.stringify({
            sessionId,
            restaurantName: input.restaurantName,
            address: input.address,
            rating: input.rating,
            category: input.category,
            description: input.description,
            photoDescriptions: input.photoDescriptions,
            visitDate: input.visitDate,
            existingRatings: input.existingRatings,
            computedScore: input.computedScore,
            photoPaths,
            debugDirectory: workDirectory,
        }),
    );

    const session: SessionRecord = {
        id: sessionId,
        clusterId: input.clusterId,
        state: "running",
        celebrating: false,
        steps: freshSteps("open_beli"),
        error: null,
        recovery: null,
        duelLog: [],
        binary,
        configPath,
        workDirectory,
        process: null,
        runVersion: 0,
        cleanupTimer: null,
    };
    sessions.set(sessionId, session);
    launchSession(session, "open_beli");
    return getBeliAutomationStatus(sessionId)!;
}

export async function retryBeliAutomation(
    sessionId: string,
    startStep: RankingStepId,
) {
    const session = sessions.get(sessionId);
    if (!session) return null;
    if (session.cleanupTimer) {
        clearTimeout(session.cleanupTimer);
        session.cleanupTimer = null;
    }
    await stopSessionProcess(session);
    session.binary = await getAutomationBinary();
    session.state = "running";
    session.celebrating = false;
    session.steps = freshSteps(startStep);
    session.error = null;
    session.recovery = null;
    launchSession(session, startStep);
    return getBeliAutomationStatus(sessionId)!;
}

export async function skipBeliAutomationStep(
    sessionId: string,
    skippedStep: RankingStepId,
) {
    const session = sessions.get(sessionId);
    const skippedIndex = RANKING_STEPS.findIndex((step) => step.id === skippedStep);
    if (!session || skippedIndex < 0) return null;
    if (session.cleanupTimer) {
        clearTimeout(session.cleanupTimer);
        session.cleanupTimer = null;
    }
    await stopSessionProcess(session);
    session.error = null;
    session.recovery = null;

    const nextStep = RANKING_STEPS[skippedIndex + 1];
    if (!nextStep) {
        session.state = "complete";
        session.celebrating = true;
        for (const step of RANKING_STEPS) session.steps[step.id] = "complete";
        scheduleCleanup(session);
        return getBeliAutomationStatus(sessionId)!;
    }

    session.binary = await getAutomationBinary();
    session.state = "running";
    session.celebrating = false;
    session.steps = freshSteps(nextStep.id);
    launchSession(session, nextStep.id);
    return getBeliAutomationStatus(sessionId)!;
}

export async function skipBeliPhotos(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session || session.recovery !== "photos_not_found") return null;
    if (session.cleanupTimer) {
        clearTimeout(session.cleanupTimer);
        session.cleanupTimer = null;
    }
    await stopSessionProcess(session);
    session.binary = await getAutomationBinary();
    session.state = "running";
    session.celebrating = false;
    session.steps = freshSteps("add_photos");
    session.error = null;
    session.recovery = null;
    launchSession(session, "skip_photos");
    return getBeliAutomationStatus(sessionId)!;
}

export async function continueBeliPhotos(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session || session.recovery !== "photos_not_found") return null;
    if (session.cleanupTimer) {
        clearTimeout(session.cleanupTimer);
        session.cleanupTimer = null;
    }
    await stopSessionProcess(session);
    session.binary = await getAutomationBinary();
    session.state = "running";
    session.celebrating = false;
    session.steps = freshSteps("add_photo_descriptions");
    session.error = null;
    session.recovery = null;
    launchSession(session, "continue_photos");
    return getBeliAutomationStatus(sessionId)!;
}

export function pauseBeliAutomation(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session || session.state !== "running" || !session.process) return null;
    if (!session.process.kill("SIGSTOP")) {
        throw new Error("Could not pause Beli automation.");
    }
    session.state = "paused";
    return getBeliAutomationStatus(sessionId)!;
}

export function resumeBeliAutomation(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session || session.state !== "paused" || !session.process) return null;
    if (!session.process.kill("SIGCONT")) {
        throw new Error("Could not resume Beli automation.");
    }
    session.state = "running";
    return getBeliAutomationStatus(sessionId)!;
}

export async function cancelBeliAutomation(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session) return null;
    if (session.cleanupTimer) {
        clearTimeout(session.cleanupTimer);
        session.cleanupTimer = null;
    }
    await stopSessionProcess(session);
    session.state = "cancelled";
    session.celebrating = false;
    session.error = null;
    session.recovery = null;
    scheduleCleanup(session);
    return getBeliAutomationStatus(sessionId)!;
}

export function getBeliAutomationStatus(sessionId: string) {
    const session = sessions.get(sessionId);
    if (!session) return null;
    const status: RankingSessionStatus = {
        id: session.id,
        clusterId: session.clusterId,
        state: session.state,
        celebrating: session.celebrating,
        steps: session.steps,
        error: session.error,
        recovery: session.recovery,
        duelLog: session.duelLog,
    };
    return structuredClone(status);
}
