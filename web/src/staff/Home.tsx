import { useMemo, useState } from 'react';
import { post } from '../api';
import { useApi, useApp, useNow } from '../state';
import { formatMoney, fmtTime } from '../format';
import { Empty, ErrorBox, Icon, Kpi, Loading, Photo, StatusBadge, levelFor, remainingFor } from '../components/ui';
import { SessionCard, SessionDetail, useAct } from '../components/actions';

export function Home({ go }: { go: (r: string) => void }) {
  const { config, can } = useApp();
  const d = useApi<any>('/dashboard');
  const waitingList = useApi<any>('/sessions?group=waiting');
  const act = useAct();
  const [open, setOpen] = useState<string | null>(null);
  useNow(5000); // re-sort urgency buckets periodically (display only)
  const live = d.data?.liveSessions ?? [];
  const warnings = config?.settings.warnings ?? [];
  const sorted = useMemo(() => [...live].sort((a: any, b: any) => (remainingFor(a) ?? 1e9) - (remainingFor(b) ?? 1e9)), [live]);
  if (d.loading && !d.data) return <div className="page"><Loading /></div>;
  if (d.error && !d.data) return <div className="page"><ErrorBox error={d.error} retry={d.reload} /></div>;
  const data = d.data!;
  const cap = data.capacity;
  const pct = cap.max ? Math.min(100, Math.round((cap.occupancy / cap.max) * 100)) : 0;
  const expired = sorted.filter((s: any) => levelFor(remainingFor(s), s.status, warnings) === 'expired');
  const cur = data.currency;
  return (
    <div className="page col gap-l touch">
      <div className="row wrap">
        {can('session.create') && <button className="btn primary big" onClick={() => go('checkin')}><Icon n="plus" size={20} /> New customer / check-in</button>}
        <button className="btn big" onClick={() => go('search')}><Icon n="search" size={20} /> Search customer</button>
        <span className="spacer" />
        <span className="muted small">{d.data ? `Updated ${fmtTime(new Date().toISOString(), true)}` : ''}</span>
      </div>

      {expired.length > 0 && <div className="banner red" role="alert"><Icon n="stop" size={20} />{expired.length} session{expired.length > 1 ? 's have' : ' has'} run out of time: {expired.map((s: any) => s.customerName).join(', ')}</div>}
      {cap.full && <div className="banner red"><Icon n="lock" size={20} />VENUE FULL — {cap.occupancy} / {cap.max}. New sessions are blocked until someone leaves.</div>}

      <div className="kpis">
        <Kpi label="Inside now" value={<>{cap.occupancy} <span className="muted" style={{ fontSize: 16 }}>/ {cap.max}</span></>} sub={<div className={`bar ${cap.full ? 'full' : pct > 85 ? 'warn' : ''}`}><i style={{ width: pct + '%' }} /></div>} />
        <Kpi label="Spaces left" value={cap.available} tone={cap.full ? 'red' : cap.available <= 5 ? 'yellow' : undefined} sub={cap.full ? 'FULL' : 'available'} />
        <Kpi label="Visitors today" value={data.today.visitors} />
        {data.today.revenueMinor !== null && <Kpi label="Revenue today" value={formatMoney(data.today.revenueMinor, cur)} />}
        <Kpi label="Waiting" value={data.waiting} sub={data.awaitingPayment ? `${data.awaitingPayment} awaiting payment` : 'paid, not started'} />
        <Kpi label="Skates out" value={data.equipment.out} sub={data.equipment.needsAttention ? `${data.equipment.needsAttention} need attention` : 'all in order'} />
        {data.openIncidents !== null && <Kpi label="Open incidents" value={data.openIncidents} tone={data.openIncidents ? 'yellow' : undefined} />}
      </div>

      <div className="card">
        <div className="row between wrap"><h2>Live rink</h2>
          <div className="row wrap"><span className="badge lvl-normal"><Icon n="play" />{data.rink.normal} normal</span><span className="badge lvl-yellow"><Icon n="warn" />{data.rink.expiring} ending soon</span><span className="badge lvl-expired"><Icon n="stop" />{data.rink.expired} time up</span></div></div>
      </div>

      {sorted.length === 0 ? <div className="card"><Empty>Nobody is skating right now.</Empty></div> :
        <div className="cards">{sorted.map((s: any) => <SessionCard key={s.id} s={s} onOpen={() => setOpen(s.id)} onChanged={d.reload} />)}</div>}

      {waitingList.data?.sessions.length > 0 && (
        <div className="card col">
          <h2>Waiting to start</h2>
          {waitingList.data.sessions.map((w: any) => (
            <div key={w.id} className="row between wrap" style={{ padding: '6px 0', borderBottom: '1px solid var(--border)' }}>
              <div className="row"><Photo id={w.photoId} name={w.customerName} size="sm" /><div><b>{w.customerName}</b><div className="muted small">{w.productName} · {w.visitNumber}</div></div><StatusBadge status={w.status} /></div>
              {can('session.create') && <button className="btn small primary" onClick={() => go(`checkin?session=${w.id}`)}>Continue check-in</button>}
            </div>))}
        </div>)}

      {data.alerts.length > 0 && (
        <div className="card col">
          <h2>Alerts <span className="muted small">(stay here until resolved)</span></h2>
          {data.alerts.map((a: any) => (
            <div key={a.id} className="row between wrap" style={{ padding: '6px 0', borderBottom: '1px solid var(--border)' }}>
              <div className="row"><span className={`badge lvl-${a.severity === 'CRITICAL' ? 'red' : a.severity === 'WARNING' ? 'yellow' : 'info'}`}><Icon n="alert" />{a.severity.toLowerCase()}</span><b>{a.title}</b>{a.body && <span className="muted small">{a.body}</span>}<span className="muted small">{fmtTime(a.createdAt)}</span></div>
              <div className="row"><button className="btn small" onClick={() => act(() => post(`/notifications/${a.id}/ack`, {}), 'Acknowledged').then(d.reload)}>Acknowledge</button><button className="btn small" onClick={() => act(() => post(`/notifications/${a.id}/ack`, { resolve: true })).then(d.reload)}>Resolve</button></div>
            </div>))}
        </div>)}
      {open && <SessionDetail id={open} onClose={() => setOpen(null)} onChanged={d.reload} />}
    </div>
  );
}

export function StatusLegend() {
  return <div className="row wrap small muted"><StatusBadge status="ACTIVE" /><StatusBadge status="EXPIRING" /><StatusBadge status="EXPIRED" /><StatusBadge status="PAUSED" /></div>;
}
