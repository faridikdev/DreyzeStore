export interface AdminApp {
  id: string;
  bundleIdentifier: string;
  name: string;
  shortDescription: string;
  description: string;
  developer: string;
  developerId: string;
  categoryId: string;
  category: string;
  repositoryId: string;
  repository: string;
  published: boolean;
  releaseCount: number;
  latestVersion: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface AppFormOptions {
  categories: Array<{ id: string; name: string; ordinal: number }>;
  repositories: Array<{ id: string; identifier: string; name: string }>;
}

export interface AdminUpload {
  id: string;
  appId: string;
  appName: string;
  appBundleIdentifier: string;
  state: string;
  expectedSize: number;
  detectedPackage: null | {
    bundleIdentifier: string;
    version: string | null;
    build: string | null;
    minimumOS: string | null;
    displayName: string | null;
    size: number | null;
    sha256: string | null;
  };
  validationError: string | null;
  releaseNotes: string;
  channel: "stable" | "beta";
  hasRightsAttestation: boolean;
  expiresAt: string;
  createdAt: string;
}

export interface AdminDashboardData {
  apps: number;
  published: number;
  drafts: number;
  releases: number;
  pendingUploads: number;
  storageBytes: number;
  recentActivity: Array<{ id: string; actor: string; action: string; resourceType: string; resourceId: string | null; createdAt: string }>;
}
