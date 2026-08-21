import { createOpenRouter } from "@openrouter/ai-sdk-provider";
import { generateText, Output } from "ai";
import { z } from "zod";

import type { LabelPhotoInput } from "./photo-types";
import { getProviderRuntime } from "./provider-runtime";
import { serializeError } from "./run-logs";
import {
  MEAL_CATEGORIES,
  mealCategorySchema,
  type GooglePlace,
  type LabelMatch,
  type LabelProvider,
  type PlaceCandidate,
} from "./stack-schema";

const CODEX_MODEL = "gpt-5.6-luna";
const OPENROUTER_MODEL = "openai/gpt-5.6-luna";

type MatchLogger = {
  write: (name: string, value: unknown) => Promise<void>;
};

export async function getLabelRuntime() {
  const runtime = await getProviderRuntime();
  return { ...runtime, provider: runtime.provider as LabelProvider };
}

function imageParts(photos: LabelPhotoInput[]) {
  return photos.map((photo) => ({
    type: "file" as const,
    mediaType: photo.mediaType,
    data: Uint8Array.from(Buffer.from(photo.data, "base64")),
  }));
}

function placeSummary(place: GooglePlace) {
  return {
    placeId: place.id,
    name: place.displayName?.text,
    address: place.formattedAddress,
    types: place.types,
    primaryType: place.primaryType,
    location: place.location,
    rating: place.rating,
    userRatingCount: place.userRatingCount,
    priceLevel: place.priceLevel,
    websiteUri: place.websiteUri,
    editorialSummary: place.editorialSummary?.text,
    services: {
      takeout: place.takeout,
      delivery: place.delivery,
      dineIn: place.dineIn,
      servesBreakfast: place.servesBreakfast,
      servesLunch: place.servesLunch,
      servesDinner: place.servesDinner,
      servesCoffee: place.servesCoffee,
      servesDessert: place.servesDessert,
      servesBeer: place.servesBeer,
      servesWine: place.servesWine,
    },
  };
}

async function runMatch(
  provider: LabelProvider,
  photos: LabelPhotoInput[],
  places: GooglePlace[],
  log: MatchLogger,
  logPrefix: string,
) {
  const outputCount = Math.min(5, places.length);
  const schema = z.object({
    category: mealCategorySchema,
    candidates: z
      .array(
        z.object({
          placeId: z.string(),
          confidence: z.number().min(0).max(1),
          reason: z.string(),
        }),
      )
      .length(outputCount),
  });
  const prompt = [
    "Identify which nearby food business these meal photos most likely came from.",
    `Classify the meal as exactly one of these categories: ${MEAL_CATEGORIES.join(", ")}.`,
    `Return exactly ${outputCount} candidates, ordered most to least likely.`,
    "Every placeId must come from the provided list and each candidate must be unique. Consider visual cuisine, menus, branding, decor, GPS proximity, place type, and business details. Keep each reason short.",
    `Nearby places:\n${JSON.stringify(places.map(placeSummary))}`,
  ].join("\n\n");
  const messages = [
    {
      role: "user" as const,
      content: [
        { type: "text" as const, text: prompt },
        ...imageParts(photos),
      ],
    },
  ];

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
        output: Output.object({ schema }),
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
      output: Output.object({ schema }),
      messages,
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

export async function matchRestaurant({
  runId,
  stackId,
  photos,
  places,
  log,
}: {
  runId: string;
  stackId: string;
  photos: LabelPhotoInput[];
  places: GooglePlace[];
  log: MatchLogger;
}): Promise<LabelMatch> {
  if (!places.length) throw new Error("No nearby food places were found");

  const runtime = await getLabelRuntime();
  await log.write(`${stackId}-runtime`, runtime);
  let provider = runtime.provider;
  let generated: Awaited<ReturnType<typeof runMatch>>;

  try {
    generated = await runMatch(provider, photos, places, log, stackId);
  } catch (error) {
    if (provider !== "codex-cli" || !process.env.OPENROUTER_API_KEY) throw error;
    await log.write(`${stackId}-codex-fallback`, {
      error: serializeError(error),
    });
    provider = "openrouter";
    generated = await runMatch(provider, photos, places, log, stackId);
  }

  await log.write(`${stackId}-model-output`, {
    provider,
    model: generated.model,
    output: generated.output,
  });

  const placesById = new Map(
    places.map((place) => [place.id!, place] as const),
  );
  const seenPlaceIds = new Set<string>();
  const candidates: PlaceCandidate[] = [];
  const validation = generated.output.candidates.map((candidate, index) => {
    const place = placesById.get(candidate.placeId);
    if (!place) {
      return {
        index,
        placeId: candidate.placeId,
        status: "unknown_place_id" as const,
      };
    }
    if (seenPlaceIds.has(candidate.placeId)) {
      return {
        index,
        placeId: candidate.placeId,
        name: place.displayName?.text,
        status: "duplicate_place_id" as const,
      };
    }
    seenPlaceIds.add(candidate.placeId);
    candidates.push({
      ...candidate,
      name: place.displayName!.text!,
      address: place.formattedAddress ?? undefined,
      place,
    });
    return {
      index,
      placeId: candidate.placeId,
      name: place.displayName?.text,
      status: "accepted" as const,
    };
  });

  const expectedCandidates = Math.min(5, places.length);
  await log.write(`${stackId}-candidate-validation`, {
    expectedCandidates,
    acceptedCandidates: candidates.length,
    validation,
    allowedPlaces: places.map((place) => ({
      placeId: place.id,
      name: place.displayName?.text,
    })),
  });
  if (candidates.length !== expectedCandidates) {
    throw new Error(
      `The model did not return ${expectedCandidates} valid nearby places`,
    );
  }

  return {
    runId,
    provider,
    model: generated.model,
    category: generated.output.category,
    candidates,
    selected: {
      placeId: candidates[0].placeId,
      name: candidates[0].name,
      source: "model",
    },
    labeledAt: new Date().toISOString(),
  };
}
