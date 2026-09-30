import { useState } from 'react';
import { useApi, useApp } from '../state';
import { fmtDate, fmtTime, fmtDuration, formatMoney, localToday, phoneDisplay, shiftDate, titleCase } from '../format';
import { Empty, ErrorBox, Icon, Loading, Modal, Photo, StatusBadge } from '../components/ui';
import { Timeline } from '../components/actions';
import { CustomerProfile } from './Search';

const FILTERS: [string, string][] = [['all', 'All'], ['completed', 'Completed'], ['active', 'Active'], ['cancelled', 'Cancelled'], ['expired', 'Expired / overtime'], ['payment_issues', 'Payment issues'], ['incidents', 'Incidents']];

/** Daily operational history: a live view over visits, sessions and payments (no separate history store). */
export function History() {
  const { can, config } = useApp();
  const [date, setDate] = useState(localToday());
  const [filter, setFilter] = useState('all');
  const [open, setOpen] = useState<string | null>(null);
  const [cust, setCust] = useState<string | null>(null);
  const d = useApi<any>(`/visits?date=${date}&filter=${filter}`);
  const today = localToday();
  return (
    <div className="page col">
      <div className="row wrap between"><h1>Visit history</h1>
        <div className="row wrap"><button className="btn" onClick={() => setDate(shiftDate(date, -1))}>‹</button><input type="date" className="input" style={{ width: 170 }} value={date} max={today} onChange={(e) => e.target.value && setDate(e.target.value)} aria-label="History date" /><button className="btn" disabled={date >= today} onClick={() => setDate(shiftDate(date, 1))}>›</button>{date !== today && <button className="btn" onClick={() => setDate(today)}>Today</button>}</div></div>
      <div className="chips">{FILTERS.map(([k, l]) => <button key={k} className={`chip ${filter === k ? 'on' : ''}`} onClick={() => setFilter(k)}>{l}</button>)}</div>
      <div className="card flush">
        {d.loading && !d.data ? <Loading /> : d.error ? <div style={{ padding: 16 }}><ErrorBox error={d.error} retry={d.reload} /></div> : !d.data?.visits.length ? <Empty>No visits for {fmtDate(date)} with this filter.</Empty> :
          <div className="tablewrap"><table className="t"><thead><tr><th>Time</th><th>Customer</th><th>Phone</th><th>Session</th><th>Duration</th>{can('payment.read') && <th className="num">Payment</th>}<th>Staff</th><th>Equipment</th><th>Status</th></tr></thead><tbody>
            {d.data.visits.map((v: any) => (
              <tr key={v.visitId} className="click" onClick={() => setOpen(v.visitId)}>
                <td className="nowrap">{fmtTime(v.checkedInAt ?? v.createdAt)}</td>
                <td><div className="row"><Photo id={v.photoId} name={v.fullName} size="sm" /><div><b>{v.fullName}</b><div className="muted tiny">{v.visitNumber}</div></div></div></td>
                <td className="nowrap">{phoneDisplay(v.phoneE164)}</td>
                <td>{v.productName ?? '—'}{v.hasIncident && <span className="badge lvl-yellow" style={{ marginLeft: 6 }}><Icon n="flag" />incident</span>}</td>
                <td className="nowrap">{v.startedAt ? `${fmtTime(v.startedAt)} – ${fmtTime(v.actualEndAt ?? v.scheduledEndAt)}` : '—'}{v.currentDurationSeconds ? <span className="muted tiny"> · {fmtDuration(v.currentDurationSeconds)}</span> : null}</td>
                {can('payment.read') && <td className="num nowrap">{formatMoney(v.paidMinor, config?.venue.currency)}<div className="muted tiny">{v.paymentMethods ? titleCase(v.paymentMethods) : ''}</div></td>}
                <td>{v.staffName?.replace(/^Demo /, '') ?? '—'}</td><td>{v.equipment || '—'}</td>
                <td>{v.sessionStatus ? <StatusBadge status={v.sessionStatus} /> : <span className="badge lvl-gray">{titleCase(v.visitStatus)}</span>}</td>
              </tr>))}</tbody></table></div>}
      </div>
      {open && <VisitModal id={open} onClose={() => setOpen(null)} onCustomer={(id) => { setOpen(null); setCust(id); }} />}
      {cust && <CustomerProfile id={cust} onClose={() => setCust(null)} />}
    </div>
  );
}

export function VisitModal({ id, onClose, onCustomer }: { id: string; onClose: () => void; onCustomer?: (id: string) => void }) {
  const v = useApi<any>(`/visits/${id}`);
  const { can } = useApp();
  const d = v.data;
  return (
    <Modal title={d ? `Visit ${d.visit.visitNumber}` : 'Visit'} onClose={onClose} size="wide">
      {v.loading && !d ? <Loading /> : v.error ? <ErrorBox error={v.error} /> : d && (
        <div className="col gap-l">
          <div className="row top"><Photo id={d.visit.photoId} name={d.visit.fullName} size="lg" />
            <div className="col gap-s"><h2>{d.visit.fullName}</h2><span className="muted">{phoneDisplay(d.visit.phoneE164)} · {d.visit.customerCode}</span>
              {onCustomer && can('customer.read') && <button className="btn small" onClick={() => onCustomer(d.visit.customerId)}>Open customer profile</button>}</div></div>
          {d.payments.length > 0 && <div><h3>Payments</h3>{d.payments.map((p: any) => <div key={p.id} className="row between"><span>{titleCase(p.purpose)} · {titleCase(p.method)}{p.providerReference ? ` · ${p.providerReference}` : ''}</span><span><b>{formatMoney(p.amountMinor)}</b>{p.refundedMinor ? <span className="muted"> (refunded {formatMoney(p.refundedMinor)})</span> : null} <span className={`badge lvl-${p.status === 'PAID' ? 'normal' : p.status === 'FAILED' ? 'red' : 'gray'}`}>{titleCase(p.status)}</span></span></div>)}</div>}
          <div><h3 style={{ marginBottom: 8 }}>Timeline</h3><Timeline events={d.timeline} /></div>
        </div>)}
    </Modal>
  );
}
