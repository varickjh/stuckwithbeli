import { createOpenRouter } from "@openrouter/ai-sdk-provider";
import { generateText, Output } from "ai";
import { z } from "zod";

import { getProviderRuntime } from "./provider-runtime";
import { serializeError } from "./run-logs";
import type { ExistingRatings, ReviewInput, ScoreProvider, ScoreResult } from "./stack-schema";

const CODEX_MODEL = "gpt-5.6-luna";
const OPENROUTER_MODEL = "openai/gpt-5.6-luna";
const MAX_CALIBRATION_ENTRIES = 300;

type ScoreLogger = {
  write: (name: string, value: unknown) => Promise<void>;
};

export async function getScoreRuntime() {
  const runtime = await getProviderRuntime();
  return { ...runtime, provider: runtime.provider as ScoreProvider };
}

const scoreSchema = z.object({
  score: z.number().min(0).max(10),
  reasoning: z.string().min(1),
});

function ratingLabel(rating: "liked" | "fine" | "disliked") {
  switch (rating) {
    case "liked":
      return "I liked it";
    case "fine":
      return "It was fine";
    case "disliked":
      return "I did not like it";
  }
}

function calibrationEntries(existingRatings: ExistingRatings) {
  const entries = Object.entries(existingRatings).sort(([, a], [, b]) => b - a);
  const truncated = entries.length > MAX_CALIBRATION_ENTRIES;
  return {
    entries: (truncated ? entries.slice(0, MAX_CALIBRATION_ENTRIES) : entries).map(
      ([name, score]) => ({ name, score }),
    ),
    truncated,
    totalEntries: entries.length,
  };
}

function buildPrompt(
  restaurantName: string,
  rating: "liked" | "fine" | "disliked",
  review: ReviewInput,
  calibration: ReturnType<typeof calibrationEntries>,
) {
  return [
    "You are scoring a restaurant visit on Beli's 0.0-10.0 rating scale (higher is better, one decimal place).",
    `Restaurant: ${restaurantName}`,
    `Overall tier the user selected: "${ratingLabel(rating)}".`,
    `The user's review (${review.source}): ${review.text}`,
    calibration.entries.length
      ? [
          "Here are the user's existing Beli scores, sorted highest to lowest, for calibration.",
          "Place the new restaurant's score relative to these — do not invent an absolute number in a vacuum.",
          calibration.truncated
            ? `Showing the top ${calibration.entries.length} of ${calibration.totalEntries} existing ratings.`
            : null,
          JSON.stringify(calibration.entries),
        ]
          .filter(Boolean)
          .join("\n")
      : "The user has no existing scored restaurants yet, so use your own judgment for an absolute score.",
    "Return a score consistent with the selected tier (liked scores should sit above fine, fine above disliked) and a short reasoning explaining how the review and the existing ratings led to that number.",
  ].join("\n\n");
}

async function runScore(
  provider: ScoreProvider,
  prompt: string,
  log: ScoreLogger,
  logPrefix: string,
) {
  const messages = [{ role: "user" as const, content: prompt }];

  if (provider === "codex-cli") {
    const providerLogs: string[] = [];
    const { codexExec } = await import("ai-sdk-provider-codex-cli");
    try {
      const result = await generateText({
        model: codexExec(CODEX_MODEL, {
          allowNpx: false,
          skipGitRepoCheck: true,
          approvalMode: "never",
          sandboxMode: "read-only",
          reasoningEffort: "medium",
          logger: {
            debug: (message) => providerLogs.push(`debug ${message}`),
            info: (message) => providerLogs.push(`info ${message}`),
            warn: (message) => providerLogs.push(`warn ${message}`),
            error: (message) => providerLogs.push(`error ${message}`),
          },
        }),
        output: Output.object({ schema: scoreSchema }),
        messages,
        include: {
          requestBody: false,
          requestMessages: false,
          responseBody: false,
        },
      });
      await log.write(`${logPrefix}-codex-provider`, {
        status: "success",
        model: CODEX_MODEL,
        logs: providerLogs,
        output: result.output,
        finishReason: result.finishReason,
        usage: result.usage,
        warnings: result.warnings,
        providerMetadata: result.providerMetadata,
      });
      return { output: result.output, model: CODEX_MODEL };
    } catch (error) {
      await log.write(`${logPrefix}-codex-provider`, {
        status: "error",
        model: CODEX_MODEL,
        logs: providerLogs,
        error: serializeError(error),
      });
      throw error;
    }
  }

  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error("OPENROUTER_API_KEY is not configured");
  const openrouter = createOpenRouter({ apiKey });
  try {
    const result = await generateText({
      model: openrouter(OPENROUTER_MODEL),
      output: Output.object({ schema: scoreSchema }),
      messages,
      maxOutputTokens: 2000,
      providerOptions: {
        openrouter: {
          reasoning: { effort: "medium", exclude: true },
        },
      },
      include: {
        requestBody: false,
        requestMessages: false,
        responseBody: false,
      },
    });
    await log.write(`${logPrefix}-openrouter-provider`, {
      status: "success",
      model: OPENROUTER_MODEL,
      output: result.output,
      finishReason: result.finishReason,
      usage: result.usage,
      warnings: result.warnings,
      providerMetadata: result.providerMetadata,
    });
    return { output: result.output, model: OPENROUTER_MODEL };
  } catch (error) {
    await log.write(`${logPrefix}-openrouter-provider`, {
      status: "error",
      model: OPENROUTER_MODEL,
      error: serializeError(error),
    });
    throw error;
  }
}

export async function scoreReview({
  runId,
  stackId,
  restaurantName,
  rating,
  review,
  existingRatings,
  log,
}: {
  runId: string;
  stackId: string;
  restaurantName: string;
  rating: "liked" | "fine" | "disliked";
  review: ReviewInput;
  existingRatings: ExistingRatings;
  log: ScoreLogger;
}): Promise<ScoreResult> {
  const runtime = await getScoreRuntime();
  await log.write(`${stackId}-runtime`, runtime);

  const calibration = calibrationEntries(existingRatings);
  await log.write(`${stackId}-calibration`, calibration);
  const prompt = buildPrompt(restaurantName, rating, review, calibration);
  await log.write(`${stackId}-prompt`, { prompt });

  let provider = runtime.provider;
  let generated: Awaited<ReturnType<typeof runScore>>;

  try {
    generated = await runScore(provider, prompt, log, stackId);
  } catch (error) {
    if (provider !== "codex-cli" || !process.env.OPENROUTER_API_KEY) throw error;
    await log.write(`${stackId}-codex-fallback`, {
      error: serializeError(error),
    });
    provider = "openrouter";
    generated = await runScore(provider, prompt, log, stackId);
  }

  const result: ScoreResult = {
    runId,
    provider,
    model: generated.model,
    score: generated.output.score,
    reasoning: generated.output.reasoning,
    scoredAt: new Date().toISOString(),
  };
  await log.write(`${stackId}-model-output`, result);
  return result;
}
