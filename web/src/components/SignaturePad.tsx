import { useEffect, useRef } from 'react';

export function SignaturePad({ onChange }: { onChange: (dataUrl: string | null) => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const drawing = useRef(false);
  const inked = useRef(false);
  useEffect(() => {
    const c = ref.current!; const dpr = Math.min(2, window.devicePixelRatio || 1);
    c.width = c.clientWidth * dpr; c.height = c.clientHeight * dpr;
    const g = c.getContext('2d')!; g.scale(dpr, dpr); g.lineWidth = 2.5; g.lineCap = 'round'; g.strokeStyle = '#111';
    const pos = (e: PointerEvent) => { const r = c.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] as const; };
    const down = (e: PointerEvent) => { drawing.current = true; c.setPointerCapture(e.pointerId); const [x, y] = pos(e); g.beginPath(); g.moveTo(x, y); };
    const move = (e: PointerEvent) => { if (!drawing.current) return; const [x, y] = pos(e); g.lineTo(x, y); g.stroke(); inked.current = true; };
    const up = () => { if (!drawing.current) return; drawing.current = false; if (inked.current) onChange(c.toDataURL('image/png')); };
    c.addEventListener('pointerdown', down); c.addEventListener('pointermove', move); c.addEventListener('pointerup', up); c.addEventListener('pointercancel', up);
    return () => { c.removeEventListener('pointerdown', down); c.removeEventListener('pointermove', move); c.removeEventListener('pointerup', up); c.removeEventListener('pointercancel', up); };
  }, [onChange]);
  return (
    <div className="col gap-s">
      <canvas ref={ref} className="sig" aria-label="Signature area" />
      <div><button className="btn small" onClick={() => { const c = ref.current!; c.getContext('2d')!.clearRect(0, 0, c.width, c.height); inked.current = false; onChange(null); }}>Clear signature</button></div>
    </div>
  );
}
