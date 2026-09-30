import { useState } from 'react';
import { ApiError, get, post } from '../api';
import { useApp, useApi } from '../state';
import { runOrQueue } from '../offline';
import { formatMoney, fmtTime, fmtDuration, fmtDateTime, titleCase } from '../format';
import { ActionButton, Countdown, Empty, ErrorBox, Field, Icon, Loading, Modal, Photo, StatusBadge, levelFor, remainingFor } from './ui';

/** Runs an API action, toasting the readable message on failure. Returns undefined when it failed. */
export function useAct() {
  const { toast } = useApp();
  return async function act<T>(fn: () => Promise<T>, ok?: string): Promise<T | undefined> {
    try { const r = await fn(); if (ok) toast('ok', ok); return r; }
    catch (e) { toast('error', e instanceof ApiError ? e.message : 'Something went wrong.'); return undefined; }
  };
}

export const isInside = (status: string) => ['ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'].includes(status);

export function ExtendModal({ session, onClose, onDone }: { session: any; onClose: () => void; onDone: () => void }) {
  const { config, can, toast } = useApp();
  const act = useAct();
  const products = useApi<any>('/products');
  const options = config?.settings.extensionOptionsMinutes ?? [];
  const methods = config?.settings.paymentMethods ?? [];
  const [minutes, setMinutes] = useState<number>(options.includes(30) ? 30 : options[0]);
  const [method, setMethod] = useState(methods[0]?.code ?? 'CASH');
  const [ref, setRef] = useState('');
  const [free, setFree] = useState(false);
  const [reason, setReason] = useState('');
  const price = products.data?.extensions.find((e: any) => e.durationMinutes === minutes)?.priceMinor ?? 0;
  const m = methods.find((x) => x.code === method);
  const cur = config?.venue.currency ?? 'ETB';

  async function submit() {
    const params = { minutes, reason: reason || undefined, complimentary: free || undefined, payment: price > 0 && !free ? { method, reference: ref || undefined } : undefined };
    const r = await act(() => runOrQueue((key) => post(`/sessions/${session.id}/extend`, params, { key }),
      { command: 'EXTEND_SESSION', sessionId: session.id, params, label: `Extend ${session.customerName} by ${minutes} min` }));
    if (!r) return;
    toast(r.queued ? 'info' : 'ok', r.queued ? 'Offline — extension queued and will sync automatically.' : `${session.customerName} extended by ${minutes} minutes.`);
    onDone(); onClose();
  }
  return (
    <Modal title={`Extend ${session.customerName}`} onClose={onClose} size="sm" footer={<><button className="btn" onClick={onClose}>Cancel</button><ActionButton className="btn primary big" onClick={submit} disabled={price > 0 && !free && m?.requiresReference && !ref.trim()}>{price > 0 && !free ? `Confirm + ${formatMoney(price, cur)}` : 'Confirm extension'}</ActionButton></>}>
      <div className="col">
        <div className="tiles">{options.map((o) => <button key={o} className={`tile ${o === minutes ? 'on' : ''}`} onClick={() => setMinutes(o)}><span className="big">+{o}</span><span className="lbl">minutes</span></button>)}</div>
        {price > 0 && !free && (<>
          <Field label="Payment method"><div className="chips">{methods.map((x) => <button key={x.code} className={`chip ${x.code === method ? 'on' : ''}`} onClick={() => setMethod(x.code)}>{x.label}</button>)}</div></Field>
          {m?.requiresReference && <Field label="Reference / receipt no."><input className="input" value={ref} onChange={(e) => setRef(e.target.value)} /></Field>}
        </>)}
        {can('payment.discount') && price > 0 && <label className="check"><input type="checkbox" checked={free} onChange={(e) => setFree(e.target.checked)} /><span>Complimentary (no charge)<br /><span className="hint">Requires a reason and is recorded in the audit log.</span></span></label>}
        {(free) && <Field label="Reason"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
        <div className="hint">New end time is calculated by the server and recorded with who extended it, from which device, and why.</div>
      </div>
    </Modal>
  );
}

export function EndConfirm({ session, onClose, onDone }: { session: any; onClose: () => void; onDone: () => void }) {
  const { config, toast } = useApp();
  const act = useAct();
  const rem = remainingFor(session) ?? 0;
  const early = rem > (config?.settings.earlyExitGraceSeconds ?? 60) && session.status !== 'EXPIRED';
  async function go() {
    const r = await act(() => runOrQueue((key) => post(`/sessions/${session.id}/end`, {}, { key }), { command: 'END_SESSION', sessionId: session.id, label: `End ${session.customerName}` }));
    if (!r) return;
    if (r.queued) toast('info', 'Offline — “end session” queued and will sync automatically.');
    else {
      toast('ok', `${session.customerName}'s session ended.`);
      if (r.result?.equipmentOutstanding?.length) toast('info', `Remember to collect: ${r.result.equipmentOutstanding.join(', ')}`);
    }
    onDone(); onClose();
  }
  return (
    <Modal title={`End ${session.customerName}'s session?`} onClose={onClose} size="sm" footer={<><button className="btn" onClick={onClose}>Keep skating</button><ActionButton className="btn solid-danger big" onClick={go}>End session</ActionButton></>}>
      <div className="col">
        <div className="row"><Photo id={session.photoId} name={session.customerName} /><div><b>{session.customerName}</b><div className="muted small">Started {fmtTime(session.startedAt)} · ends {fmtTime(session.scheduledEndAt)}</div></div></div>
        {early ? <div className="banner yellow"><Icon n="warn" />{Math.round(rem / 60)} minutes of paid time remain. This will be recorded as an early exit.</div> : <div className="banner info">Time is up or nearly up — this will be recorded as completed.</div>}
        {session.equipment && <div className="banner info"><Icon n="skate" />Equipment out: {session.equipment}. Collect it after ending.</div>}
      </div>
    </Modal>
  );
}

export function useSessionQuickActions(onDone: () => void) {
  const { toast } = useApp();
  const act = useAct();
  return {
    async pause(s: any) {
      const r = await act(() => runOrQueue((key) => post(`/sessions/${s.id}/pause`, {}, { key }), { command: 'PAUSE_SESSION', sessionId: s.id, label: `Pause ${s.customerName}` }));
      if (r) { toast(r.queued ? 'info' : 'ok', r.queued ? 'Offline — pause queued.' : `${s.customerName} paused.`); onDone(); }
    },
    async resume(s: any) {
      const r = await act(() => runOrQueue((key) => post(`/sessions/${s.id}/resume`, {}, { key }), { command: 'RESUME_SESSION', sessionId: s.id, label: `Resume ${s.customerName}` }));
      if (r) { toast(r.queued ? 'info' : 'ok', r.queued ? 'Offline — resume queued.' : `${s.customerName} resumed.`); onDone(); }
    },
  };
}

/** One live skater. Everything shown here is derived from authoritative timestamps + status. */
export function SessionCard({ s, onOpen, onChanged }: { s: any; onOpen: () => void; onChanged: () => void }) {
  const { config, can } = useApp();
  const [ext, setExt] = useState(false);
  const [end, setEnd] = useState(false);
  const quick = useSessionQuickActions(onChanged);
  const lvl = levelFor(remainingFor(s), s.status, config?.settings.warnings ?? []);
  return (
    <div className={`scard lvl-${lvl}`}>
      <div className="row top" onClick={onOpen} style={{ cursor: 'pointer' }}>
        <Photo id={s.photoId} name={s.customerName} />
        <div className="grow">
          <div className="row between top"><span className="name">{s.customerName}</span><StatusBadge status={s.status} level={lvl} /></div>
          <div className="row between"><span className="muted small">{s.productName}{s.wristband ? ` · ${s.wristband} band` : ''}</span><Countdown s={s} xl /></div>
        </div>
      </div>
      <div className="meta" onClick={onOpen} style={{ cursor: 'pointer' }}>
        <div>Started<b>{fmtTime(s.startedAt)}</b></div><div>Ends<b>{fmtTime(s.scheduledEndAt)}</b></div><div>Skates<b>{s.equipment || '—'}</b></div>
      </div>
      <div className="row wrap">
        {can('session.extend') && <button className="btn small" onClick={() => setExt(true)}><Icon n="plus" /> Extend</button>}
        {can('session.pause') && config?.settings.pause.enabled && (s.status === 'PAUSED' ? <button className="btn small" onClick={() => quick.resume(s)}><Icon n="play" /> Resume</button> : s.status !== 'EXPIRED' && <button className="btn small" onClick={() => quick.pause(s)}><Icon n="pause" /> Pause</button>)}
        <span className="spacer" />
        {can('session.end') && <button className={`btn small ${s.status === 'EXPIRED' ? 'solid-danger' : 'danger'}`} onClick={() => setEnd(true)}><Icon n="stop" /> End</button>}
      </div>
      {ext && <ExtendModal session={s} onClose={() => setExt(false)} onDone={onChanged} />}
      {end && <EndConfirm session={s} onClose={() => setEnd(false)} onDone={onChanged} />}
    </div>
  );
}

const EVENT_LABEL: Record<string, string> = {
  SESSION_CREATED: 'Session created', PAYMENT_REQUESTED: 'Payment requested', PAYMENT_CONFIRMED: 'Payment confirmed', CHECKED_IN: 'Checked in', SESSION_STARTED: 'Session started',
  SESSION_PAUSED: 'Paused', SESSION_RESUMED: 'Resumed', SESSION_EXTENDED: 'Extended', SESSION_EXPIRING: 'Entered final stretch', SESSION_EXPIRED: 'Time ran out', SESSION_ENDED: 'Session ended',
  SESSION_CANCELLED: 'Cancelled', SESSION_NO_SHOW: 'Marked as no-show', SESSION_CORRECTED: 'Corrected by manager', SESSION_REOPENED: 'Reopened by manager', VISIT_COMPLETED: 'Visit completed',
  PAYMENT_CREATED: 'Payment recorded', PAYMENT_PAID: 'Payment received', PAYMENT_REFUNDED: 'Refund issued', PAYMENT_PENDING: 'Payment pending', ISSUED: 'Equipment issued', RETURNED: 'Equipment returned',
  DAMAGED: 'Equipment damaged', INCIDENT_REPORTED: 'Incident reported',
};
export const eventLabel = (t: string) => EVENT_LABEL[t] ?? (t.startsWith('WARNING_') ? `Warning: ${t.split('_')[1]} min left` : titleCase(t));

export function describeEvent(e: any): string {
  const m = e.metadata ?? {};
  if (e.eventType === 'SESSION_EXTENDED') return `+${Math.round(m.addedSeconds / 60)} min → ends ${fmtTime(m.newEndAt)}${m.reason ? ` · ${m.reason}` : ''}`;
  if (e.eventType === 'SESSION_ENDED') return `${titleCase(m.outcome ?? '')}${m.clientIssuedAt ? ' (recorded offline)' : ''}`;
  if (e.eventType === 'SESSION_CORRECTED') return `${m.reason ?? ''}`;
  if (e.eventType === 'SESSION_RESUMED') return `Paused ${Math.round((m.pausedSeconds ?? 0) / 60)} min`;
  if (e.eventType === 'SESSION_CANCELLED') return m.reason ?? '';
  if (e.eventType === 'ISSUED' || e.eventType === 'RETURNED') return m.code ?? m.condition ?? '';
  if (e.eventType === 'PAYMENT_CREATED') return `${formatMoney(m.amountMinor)} ${titleCase(m.method ?? '')}`;
  if (e.eventType === 'PAYMENT_REFUNDED') return `${formatMoney(m.amountMinor)} · ${m.reason ?? ''}`;
  return '';
}

export function Timeline({ events }: { events: any[] }) {
  return (
    <ul className="timeline">
      {events.map((e, i) => (
        <li key={i}><div><b>{eventLabel(e.eventType)}</b> <span className="muted small">{describeEvent(e)}</span></div>
          <div className="when">{fmtDateTime(e.occurredAt)}{e.actorName ? ` · ${e.actorName}` : ''}{e.deviceName ? ` · ${e.deviceName}` : ''}</div></li>
      ))}
    </ul>
  );
}

export function SessionDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged?: () => void }) {
  const { config, can, toast } = useApp();
  const act = useAct();
  const d = useApi<any>(`/sessions/${id}`);
  const eq = useApi<any>(can('equipment.assign') ? '/equipment?status=AVAILABLE' : null);
  const [ext, setExt] = useState(false);
  const [end, setEnd] = useState(false);
  const [pick, setPick] = useState(false);
  const [fix, setFix] = useState(false);
  const [cancel, setCancel] = useState(false);
  const refresh = () => { d.reload(); onChanged?.(); };
  const quick = useSessionQuickActions(refresh);
  const s = d.data?.session;

  async function returnItem(equipmentId: string, condition: 'GOOD' | 'DAMAGED') {
    const note = condition === 'DAMAGED' ? prompt('What is wrong with it?') ?? '' : undefined;
    if (condition === 'DAMAGED' && !note?.trim()) return;
    const r = await act(() => runOrQueue((key) => post(`/equipment/${equipmentId}/return`, { condition, note }, { key }), { command: 'RETURN_EQUIPMENT', equipmentId, params: { condition, note }, label: 'Return equipment' }));
    if (r) { toast(r.queued ? 'info' : 'ok', r.queued ? 'Offline — return queued.' : 'Equipment returned.'); refresh(); }
  }
  async function issue(equipmentId: string) {
    const r = await act(() => post(`/equipment/${equipmentId}/assign`, { sessionId: id }), 'Equipment issued.');
    if (r) { setPick(false); refresh(); eq.reload(); }
  }
  return (
    <Modal title={s ? s.customerName : 'Session'} onClose={onClose} size="wide">
      {d.loading && !s ? <Loading /> : d.error ? <ErrorBox error={d.error} retry={d.reload} /> : s && (
        <div className="col gap-l">
          <div className="row top wrap">
            <Photo id={s.photoId} name={s.customerName} size="lg" />
            <div className="grow col gap-s">
              <div className="row wrap"><StatusBadge status={s.status} level={levelFor(remainingFor(s), s.status, config?.settings.warnings ?? [])} /><span className="muted">{s.visitNumber}</span></div>
              <div><Countdown s={s} xl /></div>
              <div className="meta"><div>Product<b>{s.productName}</b></div><div>Started<b>{fmtTime(s.startedAt)}</b></div><div>Ends<b>{fmtTime(s.scheduledEndAt)}</b></div>
                <div>Paid<b>{formatMoney(s.paidMinor, s.currency)} / {formatMoney(s.dueMinor, s.currency)}</b></div><div>Purchased<b>{fmtDuration(s.currentDurationSeconds)}</b></div><div>Wristband<b>{s.wristband ?? '—'}</b></div></div>
            </div>
          </div>
          <div className="row wrap">
            {isInside(s.status) && can('session.extend') && <button className="btn" onClick={() => setExt(true)}><Icon n="plus" /> Extend</button>}
            {isInside(s.status) && can('session.pause') && config?.settings.pause.enabled && (s.status === 'PAUSED' ? <button className="btn" onClick={() => quick.resume(s)}><Icon n="play" /> Resume</button> : s.status !== 'EXPIRED' && <button className="btn" onClick={() => quick.pause(s)}><Icon n="pause" /> Pause</button>)}
            {isInside(s.status) && can('session.end') && <button className="btn danger" onClick={() => setEnd(true)}><Icon n="stop" /> End session</button>}
            {['CREATED', 'PAYMENT_PENDING', 'READY'].includes(s.status) && can('session.cancel') && <button className="btn danger" onClick={() => setCancel(true)}>Cancel session</button>}
            {can('session.correct') && !['CANCELLED', 'NO_SHOW'].includes(s.status) && <button className="btn ghost" onClick={() => setFix(true)}><Icon n="gear" /> Correct…</button>}
          </div>
          <div>
            <div className="row between"><h3>Equipment</h3>{can('equipment.assign') && ['CHECKED_IN', 'ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'].includes(s.status) && <button className="btn small" onClick={() => setPick(!pick)}><Icon n="skate" /> Issue skates</button>}</div>
            {pick && <div className="chips" style={{ margin: '8px 0' }}>{(eq.data?.items ?? []).slice(0, 40).map((e: any) => <button key={e.id} className="chip" onClick={() => issue(e.id)}>{e.code}{e.size ? ` · ${e.size}` : ''}</button>)}{!eq.data?.items?.length && <span className="muted">No skates available.</span>}</div>}
            {d.data.equipmentAssignments.length === 0 ? <div className="muted small">None issued.</div> : d.data.equipmentAssignments.map((a: any) => (
              <div key={a.id} className="row between" style={{ padding: '6px 0' }}><span><b>{a.code}</b> <span className="muted small">issued {fmtTime(a.assignedAt)}{a.returnedAt ? ` · returned ${fmtTime(a.returnedAt)}` : ''}</span></span>
                {!a.returnedAt && can('equipment.return') && <span className="row"><button className="btn small" onClick={() => returnItem(a.id, 'GOOD')}>Return OK</button><button className="btn small danger" onClick={() => returnItem(a.id, 'DAMAGED')}>Damaged</button></span>}</div>))}
          </div>
          <div><h3 style={{ marginBottom: 8 }}>History</h3>{d.data.events.length ? <Timeline events={d.data.events} /> : <Empty>No events.</Empty>}</div>
        </div>
      )}
      {s && ext && <ExtendModal session={s} onClose={() => setExt(false)} onDone={refresh} />}
      {s && end && <EndConfirm session={s} onClose={() => setEnd(false)} onDone={refresh} />}
      {s && fix && <CorrectModal session={s} onClose={() => setFix(false)} onDone={refresh} />}
      {s && cancel && <CancelModal session={s} onClose={() => setCancel(false)} onDone={() => { refresh(); onClose(); }} />}
    </Modal>
  );
}

function CancelModal({ session, onClose, onDone }: { session: any; onClose: () => void; onDone: () => void }) {
  const act = useAct(); const { toast } = useApp();
  const [reason, setReason] = useState('');
  return (
    <Modal title="Cancel this session?" onClose={onClose} size="sm" footer={<><button className="btn" onClick={onClose}>Back</button><ActionButton className="btn solid-danger" disabled={reason.trim().length < 3} onClick={async () => {
      const r = await act(() => post(`/sessions/${session.id}/cancel`, { reason }), 'Session cancelled.');
      if (r) { if (r.refundDueMinor > 0) toast('info', `${formatMoney(r.refundDueMinor)} was paid — ask a manager to issue the refund.`); onDone(); onClose(); }
    }}>Cancel session</ActionButton></>}>
      <Field label="Reason (required)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} autoFocus /></Field>
    </Modal>
  );
}

function CorrectModal({ session, onClose, onDone }: { session: any; onClose: () => void; onDone: () => void }) {
  const act = useAct();
  const ended = ['COMPLETED', 'EARLY_EXIT'].includes(session.status);
  const [mins, setMins] = useState(Math.round(session.currentDurationSeconds / 60));
  const [reason, setReason] = useState('');
  const [mode, setMode] = useState<'CHANGE_DURATION' | 'REOPEN'>(ended ? 'REOPEN' : 'CHANGE_DURATION');
  return (
    <Modal title="Correct session" onClose={onClose} size="sm" footer={<><button className="btn" onClick={onClose}>Cancel</button><ActionButton className="btn primary" disabled={reason.trim().length < 3} onClick={async () => {
      const r = await act(() => post(`/sessions/${session.id}/correct`, mode === 'REOPEN' ? { action: 'REOPEN', reason } : { action: 'CHANGE_DURATION', newDurationMinutes: mins, reason }), 'Correction recorded.');
      if (r) { onDone(); onClose(); }
    }}>Apply correction</ActionButton></>}>
      <div className="col">
        <div className="banner info"><Icon n="shield" />Corrections are audited: the original value, the new value, who did it and why are all kept.</div>
        {ended ? <p>Reopen this session because it was ended by mistake.</p> : <Field label="Correct total duration (minutes)"><input className="input" type="number" min={1} max={600} value={mins} onChange={(e) => setMins(Number(e.target.value))} /></Field>}
        {!ended && <input type="hidden" value={mode} readOnly />}
        <Field label="Reason (required)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Staff selected wrong duration." /></Field>
      </div>
    </Modal>
  );
}
