import { deflateSync, crc32 } from 'node:zlib';

function chunk(type: string, data: Buffer) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0);
  return Buffer.concat([len, td, crc]);
}

/** Generates an obviously-fake avatar PNG (coloured background, head + shoulders silhouette) for demo data. */
export function demoAvatarPng(hue: number, size = 240): Buffer {
  const hsl = (h: number, s: number, l: number): [number, number, number] => {
    const k = (n: number) => (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
    const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return [Math.round(f(0) * 255), Math.round(f(8) * 255), Math.round(f(4) * 255)];
  };
  const bg = hsl(hue, 0.45, 0.82), fg = hsl(hue, 0.4, 0.45);
  const raw = Buffer.alloc((size * 3 + 1) * size);
  const cx = size / 2, headY = size * 0.4, headR = size * 0.18, shoulderY = size * 0.95, shoulderRx = size * 0.36, shoulderRy = size * 0.3;
  for (let y = 0; y < size; y++) {
    const row = y * (size * 3 + 1);
    raw[row] = 0;
    for (let x = 0; x < size; x++) {
      const head = (x - cx) ** 2 + (y - headY) ** 2 <= headR ** 2;
      const body = ((x - cx) / shoulderRx) ** 2 + ((y - shoulderY) / shoulderRy) ** 2 <= 1;
      const c = head || body ? fg : bg;
      const o = row + 1 + x * 3;
      raw[o] = c[0]; raw[o + 1] = c[1]; raw[o + 2] = c[2];
    }
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
