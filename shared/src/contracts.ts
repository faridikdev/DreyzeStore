export const APP_CATEGORIES = [
  "Utilities",
  "Developer Tools",
  "Games",
  "Emulators",
  "Media",
  "Productivity",
  "Social",
  "Customization",
  "Other",
] as const;

export type AppCategoryName = (typeof APP_CATEGORIES)[number];

export interface RepositoryScreenshot {
  url: string;
  width: number;
  height: number;
  alt: string;
}

export interface RepositoryVersion {
  version: string;
  build: string;
  versionDate: string;
  minimumOSVersion: string;
  downloadURL: string;
  sha256: string;
  size: number;
  releaseNotes: string;
  channel: "stable" | "beta";
}

export interface RepositoryApp {
  bundleIdentifier: string;
  name: string;
  developer: string;
  category: AppCategoryName;
  description: string;
  icon: string;
  screenshots: RepositoryScreenshot[];
  versions: RepositoryVersion[];
}

export interface RepositoryManifest {
  schemaVersion: 1;
  name: string;
  identifier: string;
  description: string;
  icon: string;
  generatedAt: string;
  apps: RepositoryApp[];
}

export interface Developer {
  id: string;
  name: string;
  websiteURL?: string;
}

export interface Category {
  id: string;
  name: AppCategoryName;
  appCount?: number;
}

export interface Screenshot {
  url: string;
  width: number;
  height: number;
  alt: string;
}

export interface AppVersion {
  id: string;
  version: string;
  build: string;
  versionDate: string;
  minimumOSVersion: string;
  downloadURL: string;
  sha256: string;
  size: number;
  releaseNotes: string;
  channel: "stable" | "beta";
}

export interface StoreApp {
  id: string;
  bundleIdentifier: string;
  name: string;
  developer: Developer;
  category: Category;
  description: string;
  iconURL: string;
  screenshots: Screenshot[];
  currentVersion: AppVersion;
  repositoryIdentifier: string;
  repositoryName: string;
}

export interface RepositorySource {
  identifier: string;
  name: string;
  manifestURL: string;
  addedAt: string;
  trust: "official" | "user-confirmed";
}

export interface InstalledApplication {
  bundleIdentifier: string;
  version: string;
  sourceIdentifier: string;
  lastReportedAt: string;
}

export type BackendAvailabilityState =
  | "available"
  | "requiresUserAction"
  | "unavailable"
  | "unknown";

export interface InstallationCapability {
  identifier: string;
  displayName: string;
  state: BackendAvailabilityState;
  explanation: string;
}

export interface DeviceCapabilities {
  operatingSystemVersion: string;
  installationBackends: InstallationCapability[];
}

export interface ApiEnvelope<T> {
  data: T;
  meta?: {
    requestId?: string;
    nextCursor?: string | null;
  };
}

export interface ApiErrorEnvelope {
  error: {
    code: string;
    message: string;
    requestId?: string;
    details?: Record<string, string[]>;
  };
}

export interface ApiHealth {
  status: "ok";
  database: "ready";
}
