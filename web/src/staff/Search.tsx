import { useEffect, useState } from 'react';
import { ApiError, get, patch, post } from '../api';
import { useApi, useApp } from '../state';
import { fmtDate, fmtDateTime, fmtDuration, formatMoney, phoneDisplay, titleCase } from '../format';
import { ActionButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Photo, StatusBadge } from '../components/ui';
import { useAct } from '../components/actions';

export function Search({ go }: { go: (r: string) => void }) {
  const { toast } = useApp();
  const [q, setQ] = useState('');
  const [res, setRes] = useState<any[] | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  useEffect(() => {
    if (q.trim().length < 2) { setRes(null); return; }
    const t = setTimeout(async () => {
      try { setRes((await get(`/customers?q=${encodeURIComponent(q.trim())}`)).customers); }
      catch (e) { if (e instanceof ApiError) toast('error', e.message); }
    }, 250);
    return () => clearTimeout(t);
  }, [q, toast]);
  return (
    <div className="page narrow touch col">
      <h1>Search customer</h1>
      <input className="input big" placeholder="Name, phone, or customer code…" autoFocus value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search customers" />
      {res && res.length === 0 && <div className="card"><Empty>No customers found.</Empty></div>}
      <div className="col gap-s">{res?.map((c) => (
        <button key={c.id} className="person" onClick={() => setOpen(c.id)}>
          <Photo id={c.photoId} name={c.fullName} /><div className="grow"><b>{c.fullName}</b><div className="muted small">{phoneDisplay(c.phoneE164)} · {c.customerCode}</div><div className="muted small">{c.visitCount} visits{c.lastVisitAt ? ` · last ${fmtDate(c.lastVisitAt)}` : ''}</div></div>
          {c.isActive && <span className="badge lvl-normal">Skating now</span>}{c.status !== 'ACTIVE' && <span className="badge lvl-red">{titleCase(c.status)}</span>}
        </button>))}</div>
      {open && <CustomerProfile id={open} onClose={() => setOpen(null)} onCheckIn={() => { setOpen(null); go('checkin'); }} />}
    </div>
  );
}

export function CustomerProfile({ id, onClose, onCheckIn }: { id: string; onClose: () => void; onCheckIn?: () => void }) {
  const { can, config } = useApp();
  const act = useAct();
  const c = useApi<any>(`/customers/${id}`);
  const h = useApi<any>(`/customers/${id}/history`);
  const [edit, setEdit] = useState(false);
  const d = c.data;
  return (
    <Modal title="Customer profile" onClose={onClose} size="wide">
      {c.loading && !d ? <Loading /> : c.error ? <ErrorBox error={c.error} /> : d && (
        <div className="col gap-l">
          <div className="row top wrap"><Photo id={d.photoId} name={d.fullName} size="lg" />
            <div className="grow col gap-s"><h1>{d.fullName}</h1>
              <div className="row wrap"><span className="muted">{d.customerCode}</span><span className="row gap-s"><Icon n="phone" />{phoneDisplay(d.phoneE164)}</span>{d.email && <span className="muted">{d.email}</span>}</div>
              <div className="row wrap">
                {d.status !== 'ACTIVE' && <span className="badge lvl-red">{titleCase(d.status)}</span>}
                {d.isMinor && <span className="badge lvl-info"><Icon n="shield" />Minor</span>}
                {d.waiver?.required && (d.waiver.accepted ? <span className="badge lvl-normal"><Icon n="check" />Waiver v{d.waiver.currentVersion} accepted</span> : <span className="badge lvl-yellow"><Icon n="warn" />Waiver needed</span>)}
                {d.currentSession && <span className="badge lvl-normal"><Icon n="play" />Skating now</span>}
              </div>
              <span className="muted small">Registered {fmtDate(d.registeredAt)}</span></div>
            <div className="col gap-s">{can('customer.delete') && d.status !== 'ERASED' && <button className="btn danger small" onClick={async () => {
                const reason = prompt('Privacy erasure: personal data and photos will be permanently removed; payment and audit records are kept. Reason:');
                if (reason && reason.trim().length >= 3 && await act(() => post(`/customers/${d.id}/erase`, { reason }), 'Personal data erased.')) onClose();
              }}>Erase personal data…</button>}{onCheckIn && can('session.create') && d.status === 'ACTIVE' && !d.currentSession && <button className="btn primary" onClick={onCheckIn}><Icon n="plus" /> New check-in</button>}{can('customer.update') && <button className="btn" onClick={() => setEdit(true)}>Edit</button>}</div></div>
          <div className="kpis"><div className="kpi"><div className="label">Total visits</div><div className="value">{d.stats.visitCount}</div></div><div className="kpi"><div className="label">Last visit</div><div className="value" style={{ fontSize: 18 }}>{d.stats.lastVisitAt ? fmtDate(d.stats.lastVisitAt) : '—'}</div></div>
            <div className="kpi"><div className="label">Total skating time</div><div className="value" style={{ fontSize: 22 }}>{fmtDuration(d.stats.totalSkatingSeconds)}</div></div>{can('payment.read') && <div className="kpi"><div className="label">Total spending</div><div className="value" style={{ fontSize: 22 }}>{formatMoney(d.stats.totalSpentMinor, config?.venue.currency)}</div></div>}</div>
          {d.emergencyContacts.length > 0 && <div><h3>Emergency / guardian contacts</h3>{d.emergencyContacts.map((e: any) => <div key={e.id} className="row"><b>{e.name}</b><span className="muted">{e.relationship ?? ''}{e.isGuardian ? ' · guardian' : ''}</span><a href={`tel:${e.phone}`}>{phoneDisplay(e.phone)}</a></div>)}</div>}
          {d.notes && <div className="banner info">{d.notes}</div>}
          <div><h3 style={{ marginBottom: 8 }}>Visit history</h3>
            {h.data?.history?.length ? <div className="tablewrap"><table className="t"><thead><tr><th>Date</th><th>Session</th><th>Time</th><th>Skates</th><th className="num">Paid</th><th>Status</th></tr></thead><tbody>
              {h.data.history.map((v: any) => <tr key={v.visitId}><td>{fmtDate(v.localDate)}</td><td>{v.productName ?? '—'}</td><td>{v.startedAt ? fmtDateTime(v.startedAt).split(', ').pop() : '—'}{v.actualEndAt ? ` → ${fmtDateTime(v.actualEndAt).split(', ').pop()}` : ''}</td><td>{v.equipment || '—'}</td><td className="num">{formatMoney(v.paidMinor)}</td><td>{v.sessionStatus ? <StatusBadge status={v.sessionStatus} /> : <span className="muted">{titleCase(v.visitStatus)}</span>}</td></tr>)}
            </tbody></table></div> : <Empty>No visits yet.</Empty>}</div>
        </div>)}
      {edit && d && <EditCustomer d={d} onClose={() => setEdit(false)} onSaved={() => { c.reload(); h.reload(); }} />}
    </Modal>
  );
}

function EditCustomer({ d, onClose, onSaved }: { d: any; onClose: () => void; onSaved: () => void }) {
  const act = useAct(); const { can } = useApp();
  const [f, setF] = useState({ fullName: d.fullName, phone: d.phoneE164 ?? '', email: d.email ?? '', notes: d.notes ?? '', status: d.status });
  return (
    <Modal title="Edit customer" onClose={onClose} size="sm" footer={<><button className="btn" onClick={onClose}>Cancel</button><ActionButton className="btn primary" onClick={async () => {
      const r = await act(() => patch(`/customers/${d.id}`, { fullName: f.fullName, phone: f.phone, email: f.email || null, notes: f.notes || null, status: f.status }), 'Customer updated.');
      if (r) { onSaved(); onClose(); }
    }}>Save</ActionButton></>}>
      <div className="col">
        <Field label="Full name"><input className="input" value={f.fullName} onChange={(e) => setF({ ...f, fullName: e.target.value })} /></Field>
        <Field label="Phone"><input className="input" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
        <Field label="Email"><input className="input" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
        <Field label="Notes"><textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
        {can('session.correct') && <Field label="Status"><select className="input" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}><option>ACTIVE</option><option>BLOCKED</option><option>ARCHIVED</option></select></Field>}
      </div>
    </Modal>
  );
}
