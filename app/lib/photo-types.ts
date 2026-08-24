import type {
  LabelMatch,
  MealCategory,
  PlacesSearchResult,
  RestaurantSelection,
} from "./stack-schema";

export type Photo = {
  id: string;
  checksum: string;
  name: string;
  path: string;
  url: string;
  blob?: Blob;
  mediaType: string;
  size: number;
  previewable: boolean;
  takenAt: number | null;
  latitude: number | null;
  longitude: number | null;
};

export type LabelPhotoInput = {
  id: string;
  name: string;
  takenAt: number | null;
  mediaType: string;
  data: string;
};

export type ClusterLabelStatus =
  | "ready"
  | "queued"
  | "matching"
  | "matched"
  | "error";

export type PhotoCluster = {
  id: string;
  photos: Photo[];
  ranked: boolean;
  labelStatus: ClusterLabelStatus;
  placesSearch: PlacesSearchResult | null;
  match: LabelMatch | null;
  category: MealCategory | null;
  selection: RestaurantSelection | null;
  labelError: string | null;
};

export type PhotoContextMenuState = {
  clusterId: string;
  photoId: string;
  x: number;
  y: number;
};

export const PHOTO_DRAG_TYPE = "application/x-auto-beli-photo";
