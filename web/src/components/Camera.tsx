import { useEffect, useRef, useState } from 'react';
import { Icon } from './ui';

/** Captures a still from the device camera, downscaled to <=1024px JPEG (no EXIF is produced by canvas). Falls back to a file picker. */
export function Camera({ onCapture, onSkip, skipLabel = 'Skip photo' }: { onCapture: (blob: Blob) => void; onSkip?: () => void; skipLabel?: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [shot, setShot] = useState<{ blob: Blob; url: string } | null>(null);

  useEffect(() => {
    let s: MediaStream | null = null, cancelled = false;
    (async () => {
      if (!navigator.mediaDevices?.getUserMedia) { setError('This browser cannot open the camera here. Use the button below to take or choose a photo.'); return; }
      try {
        s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 960 } }, audio: false });
        if (cancelled) { s.getTracks().forEach((t) => t.stop()); return; }
        setStream(s);
      } catch { setError('Camera access was blocked or no camera was found. Use the button below to take or choose a photo.'); }
    })();
    return () => { cancelled = true; s?.getTracks().forEach((t) => t.stop()); };
  }, []);
  useEffect(() => { if (video.current && stream) { video.current.srcObject = stream; video.current.play().catch(() => {}); } }, [stream, shot]);
  useEffect(() => () => { if (shot) URL.revokeObjectURL(shot.url); }, [shot]);

  async function snap() {
    const v = video.current; if (!v || !v.videoWidth) return;
    const scale = Math.min(1, 1024 / Math.max(v.videoWidth, v.videoHeight));
    const c = document.createElement('canvas'); c.width = Math.round(v.videoWidth * scale); c.height = Math.round(v.videoHeight * scale);
    c.getContext('2d')!.drawImage(v, 0, 0, c.width, c.height);
    const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', 0.85));
    if (blob) setShot({ blob, url: URL.createObjectURL(blob) });
  }
  async function fromFile(f: File | undefined) {
    if (!f) return;
    const bmp = await createImageBitmap(f).catch(() => null);
    if (!bmp) { setError('That file is not a readable image.'); return; }
    const scale = Math.min(1, 1024 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
    c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', 0.85));
    if (blob) setShot({ blob, url: URL.createObjectURL(blob) });
  }

  return (
    <div className="col">
      {shot ? <img src={shot.url} alt="Captured photo preview" className="video" style={{ transform: 'none' }} />
        : stream ? <video ref={video} className="video" playsInline muted autoPlay aria-label="Camera preview" /> : null}
      {error && <div className="banner yellow"><Icon n="alert" />{error}</div>}
      <div className="row wrap">
        {shot ? (<>
          <button className="btn primary big" onClick={() => onCapture(shot.blob)}><Icon n="check" /> Use this photo</button>
          <button className="btn big" onClick={() => setShot(null)}>Retake</button>
        </>) : (<>
          {stream && <button className="btn primary big" onClick={snap}><Icon n="camera" size={20} /> Take photo</button>}
          <label className="btn big" style={{ cursor: 'pointer' }}><Icon n="camera" size={20} /> {stream ? 'Choose a file' : 'Take / choose photo'}
            <input type="file" accept="image/*" capture="user" className="sr" onChange={(e) => fromFile(e.target.files?.[0])} />
          </label>
        </>)}
        {onSkip && <button className="btn ghost" onClick={onSkip}>{skipLabel}</button>}
      </div>
    </div>
  );
}
