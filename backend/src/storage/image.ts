import { createHash } from 'node:crypto';
import { config } from '../config.js';
import { AppError, E } from '../shared/errors.js';

export interface ValidatedImage {
  mime: 'image/jpeg' | 'image/png' | 'image/webp';
  ext: 'jpg' | 'png' | 'webp';
  width: number;
  height: number;
  size: number;
  sha256: string;
  /** Sanitised bytes to store (EXIF/XMP/text metadata removed). */
  bytes: Buffer;
}

/**
 * Validate an uploaded image from its actual bytes. The client-supplied Content-Type is never trusted:
 * type is sniffed from magic bytes and dimensions are parsed from the container headers.
 */
export function validateImage(buf: Buffer): ValidatedImage {
  if (!buf || buf.length === 0) throw E.badRequest('IMAGE_EMPTY', 'The uploaded photo is empty.');
  if (buf.length > config.storage.maxUploadBytes) {
    throw new AppError(413, 'IMAGE_TOO_LARGE', `The photo is too large (max ${Math.round(config.storage.maxUploadBytes / 1024 / 1024)} MB).`);
  }
  let parsed: { mime: ValidatedImage['mime']; ext: ValidatedImage['ext']; width: number; height: number } | null = null;
  if (buf.length > 4 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) parsed = parseJpeg(buf);
  else if (buf.length > 24 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) parsed = parsePng(buf);
  else if (buf.length > 30 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') parsed = parseWebp(buf);
  else throw E.badRequest('IMAGE_TYPE_NOT_ALLOWED', 'Only JPEG, PNG or WebP photos are accepted.');
  if (!parsed) throw E.badRequest('IMAGE_CORRUPT', 'The photo file is damaged or not a valid image.');
  const { width, height } = parsed;
  const { minDimension: min, maxDimension: max } = config.storage;
  if (width < min || height < min) throw E.badRequest('IMAGE_TOO_SMALL', `The photo is too small (minimum ${min}×${min} pixels).`);
  if (width > max || height > max || width * height > 25_000_000) {
    throw E.badRequest('IMAGE_DIMENSIONS', `The photo dimensions are too large (maximum ${max} pixels per side).`);
  }
  const clean = parsed.ext === 'jpg' ? stripJpegMetadata(buf) : parsed.ext === 'png' ? stripPngMetadata(buf) : buf;
  return { ...parsed, size: clean.length, sha256: createHash('sha256').update(clean).digest('hex'), bytes: clean };
}

/** Remove APP1 (EXIF/XMP, may contain GPS), APP13 (IPTC) and COM segments before the image data starts. */
export function stripJpegMetadata(b: Buffer): Buffer {
  const out: Buffer[] = [b.subarray(0, 2)];
  let i = 2;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) break;
    const marker = b[i + 1];
    if (marker === 0xda) { out.push(b.subarray(i)); return Buffer.concat(out); } // SOS: rest is entropy-coded data
    if (marker === 0xd9) { out.push(b.subarray(i)); return Buffer.concat(out); }
    if ((marker >= 0xd0 && marker <= 0xd8) || marker === 0x01) { out.push(b.subarray(i, i + 2)); i += 2; continue; }
    const len = b.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > b.length) break;
    if (!(marker === 0xe1 || marker === 0xed || marker === 0xfe)) out.push(b.subarray(i, i + 2 + len));
    i += 2 + len;
  }
  out.push(b.subarray(i));
  return Buffer.concat(out);
}

const PNG_DROP = new Set(['eXIf', 'tEXt', 'iTXt', 'zTXt', 'tIME']);
export function stripPngMetadata(b: Buffer): Buffer {
  const out: Buffer[] = [b.subarray(0, 8)];
  let i = 8;
  while (i + 12 <= b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString('ascii', i + 4, i + 8);
    const end = i + 12 + len;
    if (end > b.length) break;
    if (!PNG_DROP.has(type)) out.push(b.subarray(i, end));
    i = end;
    if (type === 'IEND') break;
  }
  return Buffer.concat(out);
}

function parseJpeg(b: Buffer) {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) { i++; continue; }
    let marker = b[i + 1];
    while (marker === 0xff) { i++; marker = b[i + 1]; }
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { i += 2; continue; }
    if (marker === 0xd9) break;
    const len = b.readUInt16BE(i + 2);
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      const height = b.readUInt16BE(i + 5);
      const width = b.readUInt16BE(i + 7);
      if (!width || !height) return null;
      return { mime: 'image/jpeg' as const, ext: 'jpg' as const, width, height };
    }
    if (len < 2) return null;
    i += 2 + len;
  }
  return null;
}

function parsePng(b: Buffer) {
  if (b.toString('ascii', 12, 16) !== 'IHDR') return null;
  const width = b.readUInt32BE(16);
  const height = b.readUInt32BE(20);
  if (!width || !height) return null;
  return { mime: 'image/png' as const, ext: 'png' as const, width, height };
}

function parseWebp(b: Buffer) {
  const fourcc = b.toString('ascii', 12, 16);
  let width = 0, height = 0;
  if (fourcc === 'VP8 ') {
    if (b.length < 30 || b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
    width = b.readUInt16LE(26) & 0x3fff;
    height = b.readUInt16LE(28) & 0x3fff;
  } else if (fourcc === 'VP8L') {
    if (b[20] !== 0x2f) return null;
    const b0 = b[21], b1 = b[22], b2 = b[23], b3 = b[24];
    width = 1 + (((b1 & 0x3f) << 8) | b0);
    height = 1 + (((b3 & 0x0f) << 10) | (b2 << 2) | ((b1 & 0xc0) >> 6));
  } else if (fourcc === 'VP8X') {
    width = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    height = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
  } else return null;
  if (!width || !height) return null;
  return { mime: 'image/webp' as const, ext: 'webp' as const, width, height };
}
