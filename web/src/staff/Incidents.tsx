import { useEffect, useState } from 'react';
import { fetchBlobUrl, post } from '../api';
import { useApi, useApp } from '../state';
import { fmtDateTime, titleCase } from '../format';
import { ActionButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Photo } from '../components/ui';
import { useAct } from '../components/actions';
import { Camera } from '../components/Camera';

const TYPES = ['Fall', 'Collision', 'Equipment', 'Medical', 'Behaviour', 'Other'];
const SEV = ['MINOR', 'MODERATE', 'SERIOUS', 'CRITICAL'];
const SEV_TONE: Record<string, string> = { MINOR: 'gray', MODERATE: 'yellow', SERIOUS: 'orange', CRITICAL: 'red' };

export function IncidentForm({ onClose, sessionId, customerId, onDone }: { onClose: () => void; sessionId?: string; customerId?: string; onDone?: () => void }) {
  const act = useAct();
  const live = useApi<any>('/sessions?group=live');
  const [f, setF] = useState({ type: 'Fall', severity: 'MINOR', description: '', action: '', location: 'Main rink', manager: false, sessionId: sessionId ?? '' });
  const [newId, setNewId] = useState<string | null>(null);
  const [shot, setShot] = useState(false);
  return (
    <Modal title={newId ? 'Incident recorded' : 'Report incident'} onClose={onClose} footer={newId ? <button className="btn primary" onClick={onClose}>Done</button> : <><button className="btn" onClick={onClose}>Cancel</button><ActionButton className="btn primary big" disabled={f.description.trim().length < 3} onClick={async () => {
      const r = await act(() => post('/incidents', { incidentType: f.type, severity: f.severity, description: f.description, actionTaken: f.action || undefined, location: f.location || undefined, managerNotified: f.manager, sessionId: f.sessionId || undefined, customerId }), 'Incident recorded.');
      if (r) { setNewId(r.id); onDone?.(); }
    }}>Submit report</ActionButton></>}>
      {newId ? <div className="col"><div className="banner ok"><Icon n="check" />Saved. Managers have been alerted{['SERIOUS', 'CRITICAL'].includes(f.severity) ? ' as a critical alert' : ''}.</div>
        {!shot ? <button className="btn" onClick={() => setShot(true)}><Icon n="camera" /> Add a photo</button> : <Camera skipLabel="Done" onSkip={() => setShot(false)} onCapture={async (b) => { await act(() => post(`/incidents/${newId}/attachments`, b, { contentType: 'image/jpeg' }), 'Photo attached.'); setShot(false); }} />}</div> : (
        <div className="col">
          <Field label="Type"><div className="chips">{TYPES.map((t) => <button key={t} className={`chip ${f.type === t ? 'on' : ''}`} onClick={() => setF({ ...f, type: t })}>{t}</button>)}</div></Field>
          <Field label="Severity"><div className="chips">{SEV.map((s) => <button key={s} className={`chip ${f.severity === s ? 'on' : ''}`} onClick={() => setF({ ...f, severity: s })}>{titleCase(s)}</button>)}</div></Field>
          <Field label="Who was involved? (optional)"><select className="input" value={f.sessionId} onChange={(e) => setF({ ...f, sessionId: e.target.value })}><option value="">— not linked to a skater —</option>{live.data?.sessions.map((s: any) => <option key={s.id} value={s.id}>{s.customerName}</option>)}</select></Field>
          <Field label="What happened?"><textarea className="input" rows={3} value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} autoFocus /></Field>
          <div className="row wrap"><div className="grow"><Field label="Action taken"><input className="input" value={f.action} onChange={(e) => setF({ ...f, action: e.target.value })} /></Field></div><div className="grow"><Field label="Location"><input className="input" value={f.location} onChange={(e) => setF({ ...f, location: e.target.value })} /></Field></div></div>
          <label className="check"><input type="checkbox" checked={f.manager} onChange={(e) => setF({ ...f, manager: e.target.checked })} /><span>Manager has been told</span></label>
        </div>)}
    </Modal>
  );
}

export function Incidents() {
  const { can } = useApp();
  const [open, setOpen] = useState<string | null>(null);
  const [form, setForm] = useState(false);
  const [onlyOpen, setOnlyOpen] = useState(true);
  const d = useApi<any>(`/incidents${onlyOpen ? '?open=true' : ''}`);
  return (
    <div className="page col">
      <div className="row between wrap"><h1>Incidents</h1><div className="row"><label className="check"><input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} />Open only</label>{can('incident.create') && <button className="btn primary" onClick={() => setForm(true)}><Icon n="flag" /> Report incident</button>}</div></div>
      {d.data?.redacted && <div className="banner info"><Icon n="lock" />You can see only the incidents you reported, without personal details.</div>}
      <div className="card flush">{d.loading && !d.data ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : !d.data?.incidents.length ? <Empty>No incidents.</Empty> :
        <div className="tablewrap"><table className="t"><thead><tr><th>No.</th><th>When</th><th>Type</th><th>Severity</th><th>Status</th>{!d.data.redacted && <th>Customer</th>}{!d.data.redacted && <th>Reported by</th>}</tr></thead><tbody>
          {d.data.incidents.map((i: any) => <tr key={i.id} className={can('incident.read') ? 'click' : ''} onClick={() => can('incident.read') && setOpen(i.id)}><td>{i.incidentNumber}</td><td className="nowrap">{fmtDateTime(i.occurredAt)}</td><td>{i.incidentType}</td><td><span className={`badge lvl-${SEV_TONE[i.severity]}`}>{titleCase(i.severity)}</span></td><td>{titleCase(i.status)}</td>{!d.data.redacted && <td>{i.customerName ?? '—'}</td>}{!d.data.redacted && <td>{i.reportedByName}</td>}</tr>)}</tbody></table></div>}</div>
      {form && <IncidentForm onClose={() => setForm(false)} onDone={d.reload} />}
      {open && <IncidentDetail id={open} onClose={() => setOpen(null)} onChanged={d.reload} />}
    </div>
  );
}

function IncidentDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { can } = useApp(); const act = useAct();
  const d = useApi<any>(`/incidents/${id}`);
  const [note, setNote] = useState('');
  const i = d.data?.incident;
  const flow: Record<string, string[]> = { REPORTED: ['ACKNOWLEDGED', 'ACTION_TAKEN', 'UNDER_REVIEW'], ACKNOWLEDGED: ['ACTION_TAKEN', 'UNDER_REVIEW', 'CLOSED'], ACTION_TAKEN: ['UNDER_REVIEW', 'CLOSED'], UNDER_REVIEW: ['ACTION_TAKEN', 'CLOSED'], CLOSED: [] };
  return (
    <Modal title={i ? `${i.incidentNumber} · ${i.incidentType}` : 'Incident'} onClose={onClose} size="wide">
      {d.loading && !i ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : i && (
        <div className="col gap-l">
          <div className="row wrap"><span className={`badge lvl-${SEV_TONE[i.severity]}`}>{titleCase(i.severity)}</span><span className="badge lvl-info">{titleCase(i.status)}</span><span className="muted">{fmtDateTime(i.occurredAt)} · {i.location ?? ''}</span></div>
          <div><b>Customer:</b> {i.customerName ?? '—'} · <b>Reported by:</b> {i.reportedByName}</div>
          <div className="card" style={{ background: 'var(--surface-2)' }}>{i.description}{i.actionTaken && <div className="muted" style={{ marginTop: 8 }}>Action taken: {i.actionTaken}</div>}</div>
          {d.data.attachments?.length > 0 && <div className="row wrap">{d.data.attachments.map((a: any) => <AttachmentImg key={a.id} id={a.id} />)}</div>}
          {can('incident.manage') && flow[i.status].length > 0 && <div className="col"><Field label="Note (required to close serious / critical incidents)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field><div className="row wrap">{flow[i.status].map((to) => <ActionButton key={to} className={`btn ${to === 'CLOSED' ? 'primary' : ''}`} onClick={async () => { if (await act(() => post(`/incidents/${id}/transition`, { to, note: note || undefined }), `Marked ${titleCase(to).toLowerCase()}.`)) { setNote(''); d.reload(); onChanged(); } }}>{titleCase(to)}</ActionButton>)}</div></div>}
          <div><h3 style={{ marginBottom: 8 }}>History</h3><ul className="timeline">{d.data.events.map((e: any, k: number) => <li key={k}><b>{titleCase(e.eventType.replace('INCIDENT_', ''))}</b>{e.metadata?.note ? <span className="muted small"> — {e.metadata.note}</span> : null}<div className="when">{fmtDateTime(e.occurredAt)} · {e.actorName}</div></li>)}</ul></div>
        </div>)}
    </Modal>
  );
}

function AttachmentImg({ id }: { id: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => { fetchBlobUrl(`/incident-attachments/${id}/content`).then(setUrl).catch(() => {}); }, [id]);
  return url ? <img src={url} alt="Incident attachment" style={{ maxWidth: 220, borderRadius: 10, border: '1px solid var(--border)' }} /> : <span className="muted">Loading photo…</span>;
}

export function Emergency({ onClose }: { onClose: () => void }) {
  const { config } = useApp();
  const e = config?.emergency ?? {};
  const rows: [string, string | undefined][] = [['Ambulance', e.ambulance], ['Police', e.police], ['Fire', e.fire], ['Venue emergency contact', e.venueContact], ['Manager on duty', e.manager]];
  return (
    <Modal title={<span className="row"><Icon n="alert" size={22} /> Emergency information</span>} onClose={onClose}>
      <div className="col">
        <div className="tiles">{rows.filter(([, v]) => v).map(([l, v]) => <div key={l} className="card col gap-s"><span className="muted small">{l}</span><a className="tel" href={`tel:${String(v).replace(/[^\d+]/g, '')}`}>{v}</a></div>)}</div>
        {e.address && <div><b>Venue address</b><div>{e.address}</div></div>}
        {e.firstAid && <div><b>First aid</b><div>{e.firstAid}</div></div>}
        <div className="hint">Stay with the injured person. Call the ambulance first, then the manager. Record an incident afterwards.</div>
      </div>
    </Modal>
  );
}
