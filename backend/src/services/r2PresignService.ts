import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";

function createS3Client(environment: WorkerEnvironment): S3Client {
  const accountId = environment.R2_ACCOUNT_ID;
  const accessKeyId = environment.R2_ACCESS_KEY_ID;
  const secretAccessKey = environment.R2_SECRET_ACCESS_KEY;
  if (!accountId || !/^[a-f0-9]{32}$/iu.test(accountId) || !accessKeyId || !secretAccessKey) {
    throw new ApiError(503, "upload_storage_unavailable", "Direct object storage uploads are not configured.");
  }
  return new S3Client({
    region: "auto",
    endpoint: "https://" + accountId + ".r2.cloudflarestorage.com",
    credentials: { accessKeyId, secretAccessKey },
    forcePathStyle: false,
  });
}

export async function presignStagingPut(
  environment: WorkerEnvironment,
  key: string,
  expectedSize: number,
  contentType = "application/octet-stream",
): Promise<string> {
  const bucket = environment.STAGING_BUCKET_NAME;
  if (!bucket) throw new ApiError(503, "upload_storage_unavailable", "Private staging storage is not configured.");
  const command = new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    ContentLength: expectedSize,
    ContentType: contentType,
    IfNoneMatch: "*",
  });
  return getSignedUrl(createS3Client(environment), command, { expiresIn: 600 });
}

export async function presignStagingGet(environment: WorkerEnvironment, key: string): Promise<string> {
  const bucket = environment.STAGING_BUCKET_NAME;
  if (!bucket) throw new ApiError(503, "upload_storage_unavailable", "Private staging storage is not configured.");
  const command = new GetObjectCommand({
    Bucket: bucket,
    Key: key,
    ResponseContentType: "application/octet-stream",
    ResponseContentDisposition: "attachment",
  });
  return getSignedUrl(createS3Client(environment), command, { expiresIn: 300 });
}
