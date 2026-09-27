import { ApiError } from "../errors.js";

export interface InspectedImage {
  contentType: "image/png" | "image/jpeg";
  width: number;
  height: number;
  extension: "png" | "jpg";
}

export function inspectImage(bytes: Uint8Array, declaredType: string, kind: "icon" | "screenshot"): InspectedImage {
  if (bytes.byteLength < 24 || bytes.byteLength > 10 * 1024 * 1024) {
    throw new ApiError(422, "unsafe_image", "The image file has an unsupported size.");
  }
  let image: InspectedImage;
  if (isPng(bytes)) image = inspectPng(bytes);
  else if (isJpeg(bytes)) image = inspectJpeg(bytes);
  else throw new ApiError(422, "unsafe_image", "Use a valid PNG or JPEG image.");
  if (image.contentType !== declaredType) {
    throw new ApiError(422, "unsafe_image", "The uploaded image does not match its declared format.");
  }
  const maximumDimension = kind === "icon" ? 1024 : 4096;
  const minimumDimension = kind === "icon" ? 64 : 320;
  if (image.width < minimumDimension || image.height < minimumDimension ||
      image.width > maximumDimension || image.height > maximumDimension ||
      image.width * image.height > (kind === "icon" ? 1_048_576 : 12_000_000) ||
      (kind === "icon" && image.width !== image.height)) {
    throw new ApiError(422, "unsafe_image", "The image dimensions are outside the allowed range.");
  }
  return image;
}

function isPng(bytes: Uint8Array): boolean {
  return bytes.length >= 8 && bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71 &&
    bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10;
}

function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

function inspectPng(bytes: Uint8Array): InspectedImage {
  let offset = 8;
  let width = 0;
  let height = 0;
  let first = true;
  let ended = false;
  let hasImageData = false;
  while (offset + 12 <= bytes.length) {
    const length = readU32(bytes, offset);
    if (length > 10 * 1024 * 1024 || offset + 12 + length > bytes.length) break;
    const type = ascii(bytes, offset + 4, 4);
    if (!/^[A-Za-z]{4}$/u.test(type)) throw new ApiError(422, "unsafe_image", "The PNG chunk stream is invalid.");
    const chunkBody = bytes.slice(offset + 4, offset + 8 + length);
    if (readU32(bytes, offset + 8 + length) !== crc32(chunkBody)) {
      throw new ApiError(422, "unsafe_image", "The PNG checksum is invalid.");
    }
    if (first && (type !== "IHDR" || length !== 13)) {
      throw new ApiError(422, "unsafe_image", "The PNG header is invalid.");
    }
    first = false;
    if (type === "IHDR") {
      width = readU32(bytes, offset + 8);
      height = readU32(bytes, offset + 12);
      const bitDepth = bytes[offset + 16]!;
      const colorType = bytes[offset + 17]!;
      const validColorType = [0, 2, 3, 4, 6].includes(colorType);
      if (!validColorType || ![8, 16].includes(bitDepth) || bytes[offset + 18] !== 0 ||
          bytes[offset + 19] !== 0 || bytes[offset + 20]! > 1) {
        throw new ApiError(422, "unsafe_image", "The PNG encoding header is not supported.");
      }
    }
    if (type === "IDAT") hasImageData = true;
    offset += 12 + length;
    if (type === "IEND") {
      ended = length === 0 && offset === bytes.length;
      break;
    }
  }
  if (!ended || !width || !height || !hasImageData) throw new ApiError(422, "unsafe_image", "The PNG image is truncated or malformed.");
  return { contentType: "image/png", extension: "png", width, height };
}

function inspectJpeg(bytes: Uint8Array): InspectedImage {
  if (bytes.length < 4 || bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    throw new ApiError(422, "unsafe_image", "The JPEG image is truncated or malformed.");
  }
  let offset = 2;
  let width = 0;
  let height = 0;
  let hasScan = false;
  while (offset + 4 <= bytes.length - 2) {
    if (bytes[offset] !== 0xff) throw new ApiError(422, "unsafe_image", "The JPEG marker stream is invalid.");
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset++]!;
    if (marker === 0xd9) break;
    if (marker === 0xda) {
      const scanHeaderLength = (bytes[offset]! << 8) | bytes[offset + 1]!;
      if (scanHeaderLength < 6 || offset + scanHeaderLength > bytes.length - 2 || bytes[offset + scanHeaderLength] !== 0xff ||
          bytes[offset + scanHeaderLength + 1] === 0xd9) {
        throw new ApiError(422, "unsafe_image", "The JPEG scan is invalid or empty.");
      }
      hasScan = true;
      break;
    }
    if ([0xd8, 0x01, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7].includes(marker)) continue;
    const length = (bytes[offset]! << 8) | bytes[offset + 1]!;
    if (length < 2 || offset + length > bytes.length) break;
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      height = (bytes[offset + 3]! << 8) | bytes[offset + 4]!;
      width = (bytes[offset + 5]! << 8) | bytes[offset + 6]!;
      break;
    }
    offset += length;
  }
  if (!width || !height || !hasScan) throw new ApiError(422, "unsafe_image", "The JPEG image is missing valid dimensions or image data.");
  return { contentType: "image/jpeg", extension: "jpg", width, height };
}

function readU32(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset]! << 24) | (bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!) >>> 0;
}

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const value of bytes) {
    crc ^= value;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function ascii(bytes: Uint8Array, offset: number, length: number): string {
  return String.fromCharCode(...bytes.slice(offset, offset + length));
}
