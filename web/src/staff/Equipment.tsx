import { useState } from 'react';
import { post } from '../api';
import { useApi, useApp } from '../state';
import { fmtTime, titleCase } from '../format';
import { ActionButton, Empty, ErrorBox, Field, Icon, Loading, Modal } from '../components/ui';
import { useAct } from '../components/actions';

const TONE: Record<string, string> = { AVAILABLE: 'normal', ISSUED: 'info', RETURNED: 'yellow', DAMAGED: 'red', MAINTENANCE: 'orange', OUT_OF_SERVICE: 'red', RESERVED: 'gray', IN_USE: 'info' };

export function Equipment() {
  const { can } = useApp();
  const act = useAct();
  const [status, setStatus] = useState('');
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const d = useApi<any>(`/equipment?status=${status}&q=${encodeURIComponent(q)}`);
  const summary = d.data?.summary ?? {};
  const statuses = ['AVAILABLE', 'ISSUED', 'RETURNED', 'DAMAGED', 'MAINTENANCE', 'OUT_OF_SERVICE'];
  async function quickReturn(e: any, condition: 'GOOD' | 'DAMAGED') {
    const note = condition === 'DAMAGED' ? prompt(`What is wrong with ${e.code}?`) : undefined;
    if (condition === 'DAMAGED' && !note?.trim()) return;
    if (await act(() => post(`/equipment/${e.id}/return`, { condition, note }), `${e.code} returned.`)) d.reload();
  }
  return (
    <div className="page col touch">
      <div className="row wrap between"><h1>Equipment</h1><input className="input" style={{ maxWidth: 260 }} placeholder="Find skate (e.g. 034)" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      <div className="chips"><button className={`chip ${!status ? 'on' : ''}`} onClick={() => setStatus('')}>All</button>{statuses.map((s) => <button key={s} className={`chip ${status === s ? 'on' : ''}`} onClick={() => setStatus(s)}>{titleCase(s)} · {summary[s] ?? 0}</button>)}</div>
      {d.loading && !d.data ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : !d.data?.items.length ? <div className="card"><Empty>No equipment matches.</Empty></div> :
        <div className="cards" style={{ gridTemplateColumns: 'repeat(auto-fill,minmax(220px,1fr))' }}>{d.data.items.map((e: any) => (
          <div key={e.id} className="card col gap-s" style={{ padding: 12 }}>
            <div className="row between" onClick={() => setOpen(e.id)} style={{ cursor: 'pointer' }}><b style={{ fontSize: 17 }}><Icon n="skate" /> {e.code}</b><span className={`badge lvl-${TONE[e.status] ?? 'gray'}`}>{titleCase(e.status)}</span></div>
            <div className="muted small">{e.size ? `Size ${e.size} · ` : ''}{titleCase(e.condition)}</div>
            {e.status === 'ISSUED' && <div className="small">With <b>{e.issuedTo ?? 'customer'}</b><div className="muted">since {fmtTime(e.issuedAt)}{e.issuedUntil ? ` · session ends ${fmtTime(e.issuedUntil)}` : ''}</div></div>}
            <div className="row wrap">
              {e.status === 'ISSUED' && can('equipment.return') && <><button className="btn small" onClick={() => quickReturn(e, 'GOOD')}>Return OK</button><button className="btn small danger" onClick={() => quickReturn(e, 'DAMAGED')}>Damaged</button></>}
              {e.status === 'RETURNED' && can('equipment.return') && <button className="btn small" onClick={async () => { if (await act(() => post(`/equipment/${e.id}/inspect`), 'Marked available.')) d.reload(); }}>Inspected OK</button>}
              {e.status === 'AVAILABLE' && can('equipment.maintenance') && <button className="btn small ghost" onClick={() => setOpen(e.id)}>Report damage…</button>}
              {['DAMAGED', 'MAINTENANCE', 'OUT_OF_SERVICE'].includes(e.status) && can('equipment.maintenance') && <button className="btn small" onClick={() => setOpen(e.id)}>Manage</button>}
            </div>
          </div>))}</div>}
      {open && <EquipmentModal id={open} onClose={() => setOpen(null)} onChanged={d.reload} />}
    </div>
  );
}

function EquipmentModal({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { can } = useApp();
  const act = useAct();
  const e = useApi<any>(`/equipment/${id}`);
  const [issue, setIssue] = useState('');
  const d = e.data;
  const run = async (fn: () => Promise<unknown>, ok: string) => { if (await act(fn, ok)) { e.reload(); onChanged(); } };
  async function photo(file: File | undefined) {
    if (!file) return;
    const bmp = await createImageBitmap(file); const scale = Math.min(1, 1024 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale); c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', 0.85));
    if (blob) run(() => post(`/equipment/${id}/maintenance/photo`, blob, { contentType: 'image/jpeg' }), 'Photo attached.');
  }
  return (
    <Modal title={d ? `${d.code} · ${titleCase(d.status)}` : 'Equipment'} onClose={onClose} size="wide">
      {e.loading && !d ? <Loading /> : e.error ? <ErrorBox error={e.error} /> : d && (
        <div className="col gap-l">
          <div className="row wrap"><span className={`badge lvl-${TONE[d.status]}`}>{titleCase(d.status)}</span><span className="muted">{d.size ? `Size ${d.size}` : ''} · issued {d.usage.timesIssued}× · repaired {d.usage.timesRepaired}×</span></div>
          {can('equipment.maintenance') && <div className="col">
            {['AVAILABLE', 'RETURNED'].includes(d.status) && <div className="row wrap"><input className="input grow" placeholder="Describe the damage (e.g. broken wheel)" value={issue} onChange={(x) => setIssue(x.target.value)} /><ActionButton className="btn danger" disabled={issue.trim().length < 3} onClick={() => run(() => post(`/equipment/${id}/damage`, { issue }), 'Reported — unit is now unavailable.').then(() => setIssue(''))}>Report damage</ActionButton></div>}
            {d.status === 'DAMAGED' && <ActionButton className="btn" onClick={() => run(() => post(`/equipment/${id}/maintenance/start`), 'Maintenance started.')}>Start maintenance</ActionButton>}
            {['MAINTENANCE', 'OUT_OF_SERVICE'].includes(d.status) && <ActionButton className="btn good" onClick={() => { const r = prompt('What was done? (optional)') ?? ''; return run(() => post(`/equipment/${id}/maintenance/complete`, { resolution: r || undefined }), 'Back in service.'); }}>Repaired — return to service</ActionButton>}
            {['AVAILABLE', 'RETURNED', 'MAINTENANCE', 'DAMAGED'].includes(d.status) && <button className="btn danger" onClick={() => { const r = prompt('Why is this unit being taken out of service?'); if (r?.trim()) run(() => post(`/equipment/${id}/out-of-service`, { reason: r }), 'Taken out of service.'); }}>Take out of service</button>}
            {['DAMAGED', 'MAINTENANCE'].includes(d.status) && <label className="btn" style={{ cursor: 'pointer', width: 'fit-content' }}><Icon n="camera" /> Attach damage photo<input type="file" accept="image/*" capture="environment" className="sr" onChange={(x) => photo(x.target.files?.[0])} /></label>}
          </div>}
          {d.maintenance.length > 0 && <div><h3>Maintenance records</h3>{d.maintenance.map((m: any) => <div key={m.id} className="row between" style={{ padding: '4px 0' }}><span>{m.issue}</span><span className="muted small">{titleCase(m.status)} · reported {fmtTime(m.reportedAt)}{m.resolution ? ` · ${m.resolution}` : ''}</span></div>)}</div>}
          <div><h3 style={{ marginBottom: 8 }}>History</h3><ul className="timeline">{d.events.map((ev: any, i: number) => <li key={i}><b>{titleCase(ev.eventType)}</b> <span className="muted small">{ev.toStatus ? `→ ${titleCase(ev.toStatus)}` : ''}</span><div className="when">{fmtTime(ev.occurredAt)} · {ev.actorName ?? 'system'}</div></li>)}</ul></div>
        </div>)}
    </Modal>
  );
}

