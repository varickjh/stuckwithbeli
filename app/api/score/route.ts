import { NextResponse } from "next/server";

import { scoreReview } from "@/app/lib/review-scorer";
import { createRunLog, serializeError } from "@/app/lib/run-logs";
import {
  scoreStackRequestSchema,
  scoreStackResponseSchema,
} from "@/app/lib/stack-schema";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function POST(request: Request) {
  const parsed = scoreStackRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid score request" }, { status: 400 });
  }

  const input = parsed.data;
  const log = await createRunLog(input.runId);

  try {
    await log.write(`${input.stackId}-request`, {
      runId: input.runId,
      stackId: input.stackId,
      restaurantName: input.restaurantName,
      rating: input.rating,
      review: input.review,
      existingRatingsCount: Object.keys(input.existingRatings).length,
    });

    const score = await scoreReview({
      runId: input.runId,
      stackId: input.stackId,
      restaurantName: input.restaurantName,
      rating: input.rating,
      review: input.review,
      existingRatings: input.existingRatings,
      log,
    });
    const response = scoreStackResponseSchema.parse({
      score,
      logDirectory: log.directory,
    });
    await log.write(`${input.stackId}-result`, response);
    return NextResponse.json(response);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Scoring failed";
    await log.write(`${input.stackId}-error`, {
      message,
      error: serializeError(error),
    });
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
