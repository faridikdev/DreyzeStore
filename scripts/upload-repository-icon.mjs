import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const accountId = process.env.R2_ACCOUNT_ID;
const accessKeyId = process.env.R2_ACCESS_KEY_ID;
const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
const bucket = process.env.PUBLIC_BUCKET_NAME;
if (!accountId || !/^[a-f0-9]{32}$/iu.test(accountId) || !accessKeyId || !secretAccessKey || !bucket) {
  throw new Error("Set R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and PUBLIC_BUCKET_NAME in your local environment.");
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bytes = await readFile(resolve(root, "backend/assets-repository-icon.png"));
const client = new S3Client({
  region: "auto",
  endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
  credentials: { accessKeyId, secretAccessKey },
});
try {
  await client.send(new PutObjectCommand({
    Bucket: bucket,
    Key: "icons/repository-default.png",
    Body: bytes,
    ContentLength: bytes.byteLength,
    ContentType: "image/png",
    CacheControl: "public, max-age=31536000, immutable",
  }));
  process.stdout.write("Uploaded the DreyzeStore repository icon to the configured public R2 bucket.\n");
} finally {
  client.destroy();
}
