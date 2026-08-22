import type { protos } from "@googlemaps/places";
import { z } from "zod";

export const coordinateSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

export type Coordinate = z.infer<typeof coordinateSchema>;

export type GooglePlace =
  protos.google.maps.places.v1.IPlace;

const googlePlaceResponseSchema = z.custom<GooglePlace>();

export const nearbySearchParametersSchema = z.object({
  languageCode: z.string().optional(),
  regionCode: z.string().length(2).optional(),
  includedTypes: z.array(z.string()).max(50).optional(),
  excludedTypes: z.array(z.string()).max(50).optional(),
  includedPrimaryTypes: z.array(z.string()).max(50).optional(),
  excludedPrimaryTypes: z.array(z.string()).max(50).optional(),
  maxResultCount: z.number().int().min(1).max(20),
  locationRestriction: z.object({
    circle: z.object({
      center: coordinateSchema,
      radius: z.number().positive().max(50_000),
    }),
  }),
  rankPreference: z.enum(["POPULARITY", "DISTANCE"]),
  routingParameters: z
    .object({
      origin: coordinateSchema,
      travelMode: z.enum(["DRIVE", "BICYCLE", "WALK", "TWO_WHEELER"]),
      routingPreference: z
        .enum([
          "TRAFFIC_UNAWARE",
          "TRAFFIC_AWARE",
          "TRAFFIC_AWARE_OPTIMAL",
        ])
        .optional(),
      routeModifiers: z
        .object({
          avoidTolls: z.boolean().optional(),
          avoidHighways: z.boolean().optional(),
          avoidFerries: z.boolean().optional(),
          avoidIndoor: z.boolean().optional(),
        })
        .optional(),
    })
    .optional(),
  includeFutureOpeningBusinesses: z.boolean().optional(),
});

export type NearbySearchParameters = z.infer<
  typeof nearbySearchParametersSchema
>;

export const placesSearchResultSchema = z.object({
  parameters: nearbySearchParametersSchema,
  places: z.array(googlePlaceResponseSchema),
  searchedAt: z.string(),
});

export type PlacesSearchResult = z.infer<typeof placesSearchResultSchema>;

export const placeCandidateSchema = z.object({
  placeId: z.string(),
  name: z.string(),
  address: z.string().optional(),
  confidence: z.number().min(0).max(1),
  reason: z.string(),
  place: googlePlaceResponseSchema,
});

export type PlaceCandidate = z.infer<typeof placeCandidateSchema>;

export const MEAL_CATEGORIES = [
  "Restaurant",
  "Bar",
  "Coffee/Tea",
  "Bakery",
  "Dessert/Ice Cream",
] as const;

export const mealCategorySchema = z.enum(MEAL_CATEGORIES);
export type MealCategory = z.infer<typeof mealCategorySchema>;

export const restaurantSelectionSchema = z.object({
  placeId: z.string().nullable(),
  name: z.string().min(1),
  source: z.enum(["model", "user"]),
});

export type RestaurantSelection = z.infer<typeof restaurantSelectionSchema>;

export const labelProviderSchema = z.enum(["codex-cli", "openrouter"]);
export type LabelProvider = z.infer<typeof labelProviderSchema>;

export const labelMatchSchema = z.object({
  runId: z.string(),
  provider: labelProviderSchema,
  model: z.string(),
  category: mealCategorySchema,
  candidates: z.array(placeCandidateSchema).max(5),
  selected: restaurantSelectionSchema.nullable(),
  labeledAt: z.string(),
});

export type LabelMatch = z.infer<typeof labelMatchSchema>;

export const labelPhotoInputSchema = z.object({
  id: z.string(),
  name: z.string(),
  takenAt: z.number().nullable(),
  mediaType: z.string().startsWith("image/"),
  data: z.string().min(1),
});

export const labelStackRequestSchema = z.object({
  runId: z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/),
  stackId: z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/),
  coordinate: coordinateSchema,
  photos: z.array(labelPhotoInputSchema).min(1),
});

export type LabelStackRequest = z.infer<typeof labelStackRequestSchema>;

export const labelStackResponseSchema = z.object({
  placesSearch: placesSearchResultSchema,
  match: labelMatchSchema,
  logDirectory: z.string(),
});

export type LabelStackResponse = z.infer<typeof labelStackResponseSchema>;

export const reviewInputSchema = z.object({
  text: z.string(),
  source: z.enum(["typed", "voice"]),
});

export type ReviewInput = z.infer<typeof reviewInputSchema>;

export const scoreProviderSchema = z.enum(["codex-cli", "openrouter"]);
export type ScoreProvider = z.infer<typeof scoreProviderSchema>;

export const existingRatingsSchema = z.record(
  z.string().min(1),
  z.number().finite().min(0).max(10),
);

export type ExistingRatings = z.infer<typeof existingRatingsSchema>;

export const scoreResultSchema = z.object({
  runId: z.string(),
  provider: scoreProviderSchema,
  model: z.string(),
  score: z.number().min(0).max(10),
  reasoning: z.string().min(1),
  scoredAt: z.string(),
});

export type ScoreResult = z.infer<typeof scoreResultSchema>;

export const scoreStackRequestSchema = z.object({
  runId: z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/),
  stackId: z.string().regex(/^[a-zA-Z0-9_-]{1,100}$/),
  restaurantName: z.string().min(1),
  rating: z.enum(["liked", "fine", "disliked"]),
  review: reviewInputSchema,
  existingRatings: existingRatingsSchema,
});

export type ScoreStackRequest = z.infer<typeof scoreStackRequestSchema>;

export const scoreStackResponseSchema = z.object({
  score: scoreResultSchema,
  logDirectory: z.string(),
});

export type ScoreStackResponse = z.infer<typeof scoreStackResponseSchema>;
