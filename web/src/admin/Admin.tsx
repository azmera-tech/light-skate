import { useMemo, useState, type ReactNode } from 'react';
import { patch, post } from '../api';
import { useApi, useApp } from '../state';
import { fmtDate, fmtDateTime, fmtDuration, fmtTime, formatMoney, localToday, phoneDisplay, shiftDate, titleCase, toMinor } from '../format';
import { ActionButton, Empty, ErrorBox, Field, Icon, Kpi, Loading, Modal, Photo } from '../components/ui';
import { useAct } from '../components/actions';
import { History } from '../staff/History';
import { Equipment } from '../staff/Equipment';
import { Incidents } from '../staff/Incidents';
import { CustomerProfile } from '../staff/Search';
import { Settings } from './Settings';

export const ADMIN_PAGES: { key: string; label: string; icon: string; perm: string[] }[] = [
  { key: 'overview', label: 'Overview', icon: 'home', perm: ['reports.read'] },
  { key: 'customers', label: 'Customers', icon: 'user', perm: ['customer.read'] },
  { key: 'visits', label: 'Visits & sessions', icon: 'list', perm: ['visit.read'] },
  { key: 'payments', label: 'Payments', icon: 'card', perm: ['payment.read'] },
  { key: 'equipment', label: 'Equipment', icon: 'skate', perm: ['equipment.read'] },
  { key: 'incidents', label: 'Incidents', icon: 'flag', perm: ['incident.read'] },
  { key: 'staff', label: 'Staff', icon: 'shield', perm: ['staff.manage'] },
  { key: 'reports', label: 'Reports', icon: 'chart', perm: ['reports.read'] },
  { key: 'pricing', label: 'Pricing', icon: 'card', perm: ['pricing.manage'] },
  { key: 'settings', label: 'Capacity & settings', icon: 'gear', perm: ['settings.manage', 'capacity.manage'] },
  { key: 'devices', label: 'Devices', icon: 'wifi', perm: ['device.manage'] },
  { key: 'dayclose', label: 'Close day', icon: 'lock', perm: ['dayclose.manage'] },
  { key: 'audit', label: 'Audit log', icon: 'shield', perm: ['audit.read'] },
];

/** Having only day-to-day staff permissions does not unlock the admin area. */
export const MANAGEMENT_PERMS = ['reports.read', 'staff.manage', 'settings.manage', 'pricing.manage', 'capacity.manage', 'audit.read', 'device.manage', 'dayclose.manage', 'incident.read', 'equipment.manage', 'payment.refund'];

export function Admin({ page, nav }: { page: string; nav: (p: string) => void }) {
  const { can } = useApp();
  const pages = ADMIN_PAGES.filter((p) => p.perm.some((x) => can(x)));
  const current = pages.find((p) => p.key === page) ?? pages[0];
  return (
    <div className="admin-shell">
      <nav className="side" aria-label="Admin navigation">{pages.map((p) => <button key={p.key} className={`tab ${current?.key === p.key ? 'active' : ''}`} onClick={() => nav(p.key)}><Icon n={p.icon} size={18} />{p.label}</button>)}</nav>
      <main>
        {current?.key === 'overview' && <Overview />}
        {current?.key === 'customers' && <Customers />}
        {current?.key === 'visits' && <History />}
        {current?.key === 'payments' && <Payments />}
        {current?.key === 'equipment' && <div><Equipment /><AddEquipment /></div>}
        {current?.key === 'incidents' && <Incidents />}
        {current?.key === 'staff' && <Staff />}
        {current?.key === 'reports' && <Reports />}
        {current?.key === 'pricing' && <Pricing />}
        {current?.key === 'settings' && <Settings />}
        {current?.key === 'devices' && <Devices />}
        {current?.key === 'dayclose' && <DayClose />}
        {current?.key === 'audit' && <Audit />}
      </main>
    </div>
  );
}

function Section({ title, sub, right, children }: { title: string; sub?: string; right?: ReactNode; children: ReactNode }) {
  return <div className="page col"><div className="row between wrap"><div><h1>{title}</h1>{sub && <div className="muted">{sub}</div>}</div>{right}</div>{children}</div>;
}

/** Simple accessible bar chart (inline SVG; every bar carries a text label). */
export function Bars({ data, fmt = (n: number) => String(n), height = 170 }: { data: { label: string; value: number }[]; fmt?: (n: number) => string; height?: number }) {
  const max = Math.max(1, ...data.map((d) => d.value));
  const w = Math.max(320, data.length * 44);
  return (
    <svg className="chart" viewBox={`0 0 ${w} ${height}`} role="img" aria-label="Bar chart" preserveAspectRatio="xMidYMid meet" style={{ height }}>
      <line x1="0" x2={w} y1={height - 24} y2={height - 24} />
      {data.map((d, i) => { const bw = 28, x = i * 44 + 8, h = Math.round(((height - 54) * d.value) / max); return (
        <g key={i}><rect className="b" x={x} y={height - 24 - h} width={bw} height={h} rx="4" /><text x={x + bw / 2} y={height - 10} textAnchor="middle">{d.label}</text>{d.value > 0 && <text x={x + bw / 2} y={height - 28 - h} textAnchor="middle">{fmt(d.value)}</text>}</g>); })}
    </svg>
  );
}

// =============================================================== overview
function Overview() {
  const { can, config } = useApp();
  const cur = config?.venue.currency;
  const dash = useApi<any>('/dashboard');
  const rep = useApi<any>(can('reports.read') ? '/reports/daily' : null);
  const week = useApi<any>(can('reports.read') ? `/reports/range?from=${shiftDate(localToday(), -6)}&to=${localToday()}&group=day` : null);
  if (dash.loading && !dash.data) return <Section title="Overview"><Loading /></Section>;
  if (dash.error && !dash.data) return <Section title="Overview"><ErrorBox error={dash.error} /></Section>;
  const d = dash.data!, r = rep.data;
  return (
    <Section title="Overview" sub={`${config?.venue.name} · ${fmtDate(d.localDate)}`}>
      <div className="kpis">
        <Kpi label="Visitors today" value={d.today.visitors} /><Kpi label="Revenue today" value={formatMoney(d.today.revenueMinor, cur)} />
        <Kpi label="Active now" value={`${d.capacity.occupancy} / ${d.capacity.max}`} tone={d.capacity.full ? 'red' : undefined} sub={d.capacity.full ? 'FULL' : `${d.capacity.available} spaces`} />
        <Kpi label="Waiting" value={d.waiting} /><Kpi label="Ending soon / time up" value={`${d.rink.expiring} / ${d.rink.expired}`} tone={d.rink.expired ? 'red' : d.rink.expiring ? 'yellow' : undefined} />
        <Kpi label="Skates out" value={d.equipment.out} sub={`${d.equipment.needsAttention} need attention`} /><Kpi label="Open incidents" value={d.openIncidents ?? '—'} tone={d.openIncidents ? 'yellow' : undefined} />
      </div>
      {r && <div className="kpis">
        <Kpi label="Completed sessions" value={r.sessions.completed} /><Kpi label="Average session" value={fmtDuration(r.averageSessionSeconds)} /><Kpi label="Capacity utilisation" value={`${r.capacityUtilizationPercent}%`} />
        <Kpi label="Refunds today" value={formatMoney(r.revenue.refundsMinor, cur)} /><Kpi label="Cancelled / no-shows" value={`${r.sessions.cancelled} / ${r.sessions.noShows}`} /><Kpi label="Extensions" value={r.sessions.extensions} /></div>}
      <div className="row wrap top">
        {r && <div className="card grow col"><h2>Session starts by hour</h2><Bars data={r.hourlyStarts.map((h: any) => ({ label: String(h.hour).padStart(2, '0'), value: h.sessions }))} /></div>}
        {week.data && <div className="card grow col"><h2>Revenue — last 7 days</h2><Bars data={week.data.rows.map((x: any) => ({ label: x.period.slice(5), value: Math.round(x.revenueMinor / 100) }))} fmt={(n) => n.toLocaleString()} /></div>}
      </div>
      {d.alerts.length > 0 && <div className="card col"><h2>Open alerts</h2>{d.alerts.map((a: any) => <div key={a.id} className="row"><span className={`badge lvl-${a.severity === 'CRITICAL' ? 'red' : 'yellow'}`}><Icon n="alert" />{a.severity.toLowerCase()}</span><b>{a.title}</b><span className="muted small">{fmtTime(a.createdAt)}</span></div>)}</div>}
    </Section>
  );
}

// =============================================================== customers
function Customers() {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const list = useApi<any>(`/customers?${q.trim().length >= 2 ? 'q=' + encodeURIComponent(q.trim()) : 'limit=100'}`, [q]);
  return (
    <Section title="Customers" right={<input className="input" style={{ maxWidth: 300 }} placeholder="Search name, phone, code…" value={q} onChange={(e) => setQ(e.target.value)} />}>
      <div className="card flush">{list.loading && !list.data ? <Loading /> : !list.data?.customers.length ? <Empty>No customers.</Empty> :
        <div className="tablewrap"><table className="t"><thead><tr><th>Customer</th><th>Phone</th><th>Code</th><th className="num">Visits</th><th>Last visit</th><th>Status</th></tr></thead><tbody>
          {list.data.customers.map((c: any) => <tr key={c.id} className="click" onClick={() => setOpen(c.id)}><td><div className="row"><Photo id={c.photoId} name={c.fullName} size="sm" /><b>{c.fullName}</b></div></td><td>{phoneDisplay(c.phoneE164)}</td><td>{c.customerCode}</td><td className="num">{c.visitCount}</td><td>{c.lastVisitAt ? fmtDate(c.lastVisitAt) : '—'}</td><td>{c.status === 'ACTIVE' ? (c.isActive ? <span className="badge lvl-normal">Skating now</span> : <span className="muted">Active</span>) : <span className="badge lvl-red">{titleCase(c.status)}</span>}</td></tr>)}</tbody></table></div>}</div>
      {open && <CustomerProfile id={open} onClose={() => setOpen(null)} />}
    </Section>
  );
}

// =============================================================== payments
function Payments() {
  const { can, config } = useApp();
  const [date, setDate] = useState(localToday());
  const [open, setOpen] = useState<string | null>(null);
  const d = useApi<any>(`/payments?date=${date}`);
  const cur = config?.venue.currency;
  const total = (d.data?.payments ?? []).reduce((a: number, p: any) => a + (['PAID', 'PARTIALLY_REFUNDED', 'REFUNDED'].includes(p.status) ? p.amountMinor - p.refundedMinor : 0), 0);
  return (
    <Section title="Payments" sub={`Net received on ${fmtDate(date)}: ${formatMoney(total, cur)}`} right={<input type="date" className="input" style={{ width: 170 }} value={date} max={localToday()} onChange={(e) => e.target.value && setDate(e.target.value)} />}>
      <div className="card flush">{d.loading && !d.data ? <Loading /> : !d.data?.payments.length ? <Empty>No payments on this day.</Empty> :
        <div className="tablewrap"><table className="t"><thead><tr><th>Time</th><th>Customer</th><th>Visit</th><th>Method</th><th>Purpose</th><th className="num">Amount</th><th className="num">Refunded</th><th>Status</th><th>Staff</th></tr></thead><tbody>
          {d.data.payments.map((p: any) => <tr key={p.id} className="click" onClick={() => setOpen(p.id)}><td>{fmtTime(p.createdAt)}</td><td>{p.customerName}</td><td className="muted">{p.visitNumber}</td><td>{titleCase(p.method)}</td><td>{titleCase(p.purpose)}</td><td className="num">{formatMoney(p.amountMinor, p.currency)}</td><td className="num">{p.refundedMinor ? formatMoney(p.refundedMinor, p.currency) : '—'}</td><td><span className={`badge lvl-${p.status === 'PAID' ? 'normal' : ['FAILED', 'CANCELLED'].includes(p.status) ? 'red' : p.status === 'PENDING' ? 'yellow' : 'gray'}`}>{titleCase(p.status)}</span></td><td>{p.staffName}</td></tr>)}</tbody></table></div>}</div>
      {open && <PaymentModal id={open} onClose={() => setOpen(null)} onChanged={d.reload} canRefund={can('payment.refund')} />}
    </Section>
  );
}

function PaymentModal({ id, onClose, onChanged, canRefund }: { id: string; onClose: () => void; onChanged: () => void; canRefund: boolean }) {
  const act = useAct();
  const d = useApi<any>(`/payments/${id}`);
  const p = d.data;
  const [amt, setAmt] = useState(''); const [reason, setReason] = useState('');
  return (
    <Modal title="Payment" onClose={onClose} size="wide">
      {d.loading && !p ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : p && (
        <div className="col gap-l">
          <div className="kpis"><Kpi label="Amount" value={formatMoney(p.amountMinor, p.currency)} /><Kpi label="Refunded" value={formatMoney(p.refundedMinor, p.currency)} /><Kpi label="Status" value={titleCase(p.status)} /><Kpi label="Method" value={titleCase(p.method)} sub={p.providerReference ?? ''} /></div>
          {canRefund && ['PAID', 'PARTIALLY_REFUNDED'].includes(p.status) && <div className="card col"><h3>Issue refund</h3>
            <div className="row wrap"><Field label={`Amount (${p.currency}, blank = all remaining)`}><input className="input" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} /></Field><div className="grow"><Field label="Reason (required)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div></div>
            <ActionButton className="btn solid-danger" disabled={reason.trim().length < 3 || (amt !== '' && toMinor(amt) === null)} onClick={async () => { if (await act(() => post(`/payments/${id}/refund`, { amountMinor: amt ? toMinor(amt)! : undefined, reason }), 'Refund issued.')) { setAmt(''); setReason(''); d.reload(); onChanged(); } }}>Refund</ActionButton></div>}
          <div><h3 style={{ marginBottom: 8 }}>Ledger & events</h3><ul className="timeline">{p.events.map((e: any, i: number) => <li key={i}><b>{titleCase(e.eventType.replace('PAYMENT_', ''))}</b> <span className="muted small">{e.metadata?.amountMinor ? formatMoney(e.metadata.amountMinor, p.currency) : ''} {e.metadata?.reason ?? ''}</span><div className="when">{fmtDateTime(e.occurredAt)} · {e.actorName ?? 'system'}</div></li>)}</ul></div>
        </div>)}
    </Modal>
  );
}

// =============================================================== equipment add
function AddEquipment() {
  const { can } = useApp(); const act = useAct();
  const [code, setCode] = useState(''); const [size, setSize] = useState('');
  if (!can('equipment.manage')) return null;
  return <div className="page"><div className="card row wrap"><b>Add equipment</b><input className="input" style={{ maxWidth: 200 }} placeholder="Code e.g. SKATE-041" value={code} onChange={(e) => setCode(e.target.value)} /><input className="input" style={{ maxWidth: 120 }} placeholder="Size" value={size} onChange={(e) => setSize(e.target.value)} />
    <ActionButton className="btn primary" disabled={code.trim().length < 2} onClick={async () => { if (await act(() => post('/equipment', { code, size: size || undefined }), 'Equipment added.')) { setCode(''); setSize(''); } }}>Add</ActionButton></div></div>;
}

// =============================================================== staff
function Staff() {
  const act = useAct();
  const s = useApi<any>('/staff'); const roles = useApi<any>('/roles');
  const [add, setAdd] = useState(false);
  const [f, setF] = useState({ fullName: '', email: '', password: '', roleId: '' });
  return (
    <Section title="Staff" sub="Roles decide what each person can do. The server checks permissions on every request." right={<button className="btn primary" onClick={() => setAdd(true)}><Icon n="plus" /> Add staff</button>}>
      <div className="card flush">{s.loading && !s.data ? <Loading /> : s.error ? <ErrorBox error={s.error} /> :
        <div className="tablewrap"><table className="t"><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Last sign-in</th><th /></tr></thead><tbody>
          {s.data.staff.map((u: any) => <tr key={u.id}><td><b>{u.fullName}</b></td><td>{u.email}</td>
            <td><select className="input" style={{ minWidth: 150 }} value={u.roleId} onChange={async (e) => { if (await act(() => patch(`/staff/${u.id}`, { roleId: e.target.value }), 'Role changed.')) s.reload(); }}>{roles.data?.roles.map((r: any) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></td>
            <td><span className={`badge lvl-${u.status === 'ACTIVE' ? 'normal' : 'red'}`}>{titleCase(u.status)}</span></td><td>{u.lastLoginAt ? fmtDateTime(u.lastLoginAt) : 'never'}</td>
            <td className="row"><button className="btn small" onClick={async () => { if (await act(() => patch(`/staff/${u.id}`, { status: u.status === 'ACTIVE' ? 'DISABLED' : 'ACTIVE' }), 'Updated.')) s.reload(); }}>{u.status === 'ACTIVE' ? 'Disable' : 'Enable'}</button>
              <button className="btn small" onClick={async () => { const pw = prompt('New temporary password (min 10 characters):'); if (pw) await act(() => post(`/staff/${u.id}/reset-password`, { password: pw }), 'Password reset; they were signed out.'); }}>Reset password</button></td></tr>)}</tbody></table></div>}</div>
      {roles.data && <div className="card col"><h2>Role permissions</h2><div className="tablewrap"><table className="t"><thead><tr><th>Permission</th>{roles.data.roles.map((r: any) => <th key={r.id} style={{ textAlign: 'center' }}>{r.name}</th>)}</tr></thead><tbody>
        {Object.entries(roles.data.permissions).map(([code, desc]) => <tr key={code}><td><b>{code}</b><div className="muted tiny">{desc as string}</div></td>{roles.data.roles.map((r: any) => <td key={r.id} style={{ textAlign: 'center' }}>{r.permissions.includes(code) ? <span className="lvl-normal badge">✓</span> : <span className="muted">—</span>}</td>)}</tr>)}</tbody></table></div></div>}
      {add && <Modal title="Add staff member" onClose={() => setAdd(false)} size="sm" footer={<><button className="btn" onClick={() => setAdd(false)}>Cancel</button><ActionButton className="btn primary" disabled={!f.fullName || !f.email || f.password.length < 10 || !f.roleId} onClick={async () => { if (await act(() => post('/staff', f), 'Staff member added.')) { setAdd(false); setF({ fullName: '', email: '', password: '', roleId: '' }); s.reload(); } }}>Create</ActionButton></>}>
        <div className="col"><Field label="Full name"><input className="input" value={f.fullName} onChange={(e) => setF({ ...f, fullName: e.target.value })} /></Field><Field label="Email"><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
          <Field label="Temporary password" hint="At least 10 characters"><input className="input" type="text" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /></Field>
          <Field label="Role"><select className="input" value={f.roleId} onChange={(e) => setF({ ...f, roleId: e.target.value })}><option value="">Choose…</option>{roles.data?.roles.map((r: any) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></Field></div></Modal>}
    </Section>
  );
}

// =============================================================== reports
function download(name: string, rows: (string | number)[][]) {
  const csv = rows.map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function Reports() {
  const { config } = useApp();
  const cur = config?.venue.currency;
  const [mode, setMode] = useState<'daily' | 'range'>('daily');
  const [date, setDate] = useState(localToday());
  const [from, setFrom] = useState(shiftDate(localToday(), -29)); const [to, setTo] = useState(localToday()); const [group, setGroup] = useState<'day' | 'week' | 'month'>('day');
  const daily = useApi<any>(mode === 'daily' ? `/reports/daily?date=${date}` : null);
  const range = useApi<any>(mode === 'range' ? `/reports/range?from=${from}&to=${to}&group=${group}` : null);
  const r = daily.data, g = range.data;
  return (
    <Section title="Reports" right={<div className="chips"><button className={`chip ${mode === 'daily' ? 'on' : ''}`} onClick={() => setMode('daily')}>Daily</button><button className={`chip ${mode === 'range' ? 'on' : ''}`} onClick={() => setMode('range')}>Range</button></div>}>
      {mode === 'daily' ? (<>
        <div className="row wrap"><button className="btn" onClick={() => setDate(shiftDate(date, -1))}>‹</button><input type="date" className="input" style={{ width: 170 }} value={date} max={localToday()} onChange={(e) => e.target.value && setDate(e.target.value)} /><button className="btn" disabled={date >= localToday()} onClick={() => setDate(shiftDate(date, 1))}>›</button></div>
        {daily.loading && !r ? <Loading /> : daily.error ? <ErrorBox error={daily.error} /> : r && <>
          <div className="kpis"><Kpi label="Visitors" value={r.visitors} sub={`${r.newCustomers} new customers`} /><Kpi label="Net revenue" value={formatMoney(r.revenue.netMinor, cur)} sub={`${formatMoney(r.revenue.chargesMinor, cur)} in · ${formatMoney(r.revenue.refundsMinor, cur)} refunded`} /><Kpi label="Discounts" value={formatMoney(r.revenue.discountsMinor, cur)} />
            <Kpi label="Sessions started" value={r.sessions.started} sub={`${r.sessions.completed} completed · ${r.sessions.earlyExits} left early`} /><Kpi label="Active now" value={r.sessions.active} /><Kpi label="Cancelled / no-show" value={`${r.sessions.cancelled} / ${r.sessions.noShows}`} />
            <Kpi label="Average session" value={fmtDuration(r.averageSessionSeconds)} /><Kpi label="Capacity utilisation" value={`${r.capacityUtilizationPercent}%`} sub={`capacity ${r.maxCapacity}`} /><Kpi label="Equipment issues" value={r.equipment.issues} sub={`${r.equipment.distinctUnits} different units`} /><Kpi label="Incidents" value={r.incidents.total} sub={Object.entries(r.incidents.bySeverity).map(([k, v]) => `${v} ${k.toLowerCase()}`).join(', ')} /></div>
          <div className="row wrap top"><div className="card grow col"><h2>Session starts by hour</h2><Bars data={r.hourlyStarts.map((h: any) => ({ label: String(h.hour).padStart(2, '0'), value: h.sessions }))} /></div>
            <div className="card grow col"><h2>Revenue by payment method</h2>{r.revenue.byMethod.length ? <table className="t"><thead><tr><th>Method</th><th className="num">Payments</th><th className="num">Received</th><th className="num">Refunded</th></tr></thead><tbody>{r.revenue.byMethod.map((m: any) => <tr key={m.method}><td>{titleCase(m.method)}</td><td className="num">{m.count}</td><td className="num">{formatMoney(m.chargesMinor, cur)}</td><td className="num">{formatMoney(m.refundsMinor, cur)}</td></tr>)}</tbody></table> : <Empty>No payments.</Empty>}</div></div></>}
      </>) : (<>
        <div className="row wrap"><Field label="From"><input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} /></Field><Field label="To"><input type="date" className="input" value={to} max={localToday()} onChange={(e) => setTo(e.target.value)} /></Field>
          <Field label="Group by"><select className="input" value={group} onChange={(e) => setGroup(e.target.value as any)}><option value="day">Day</option><option value="week">Week</option><option value="month">Month</option></select></Field>
          <div className="row" style={{ alignSelf: 'end' }}>{g && <button className="btn" onClick={() => download(`light-skate-${from}_${to}.csv`, [['Period', 'Sessions started', 'Sessions completed', 'Unique customers', 'Revenue (net, minor units)', 'Refunds (minor)', 'Discounts (minor)', 'Avg session (s)'], ...g.rows.map((x: any) => [x.period, x.sessionsStarted, x.sessionsCompleted, x.uniqueCustomers, x.revenueMinor, x.refundsMinor, x.discountsMinor, x.averageSessionSeconds])])}>Download CSV</button>}</div></div>
        {range.loading && !g ? <Loading /> : range.error ? <ErrorBox error={range.error} /> : g && <>
          <div className="kpis"><Kpi label="Net revenue" value={formatMoney(g.totals.revenueMinor, cur)} /><Kpi label="Sessions started" value={g.totals.sessionsStarted} /><Kpi label="Completed" value={g.totals.sessionsCompleted} /><Kpi label="Refunds" value={formatMoney(g.totals.refundsMinor, cur)} /><Kpi label="Discounts" value={formatMoney(g.totals.discountsMinor, cur)} /></div>
          <div className="card col"><h2>Revenue per {group}</h2><Bars data={g.rows.map((x: any) => ({ label: group === 'month' ? x.period.slice(2, 7) : x.period.slice(5), value: Math.round(x.revenueMinor / 100) }))} fmt={(n) => n.toLocaleString()} /></div>
          <div className="card flush"><div className="tablewrap"><table className="t"><thead><tr><th>Period</th><th className="num">Sessions</th><th className="num">Completed</th><th className="num">Customers</th><th className="num">Avg session</th><th className="num">Revenue (net)</th><th className="num">Refunds</th></tr></thead><tbody>{g.rows.map((x: any) => <tr key={x.period}><td>{fmtDate(x.period)}</td><td className="num">{x.sessionsStarted}</td><td className="num">{x.sessionsCompleted}</td><td className="num">{x.uniqueCustomers}</td><td className="num">{fmtDuration(x.averageSessionSeconds)}</td><td className="num">{formatMoney(x.revenueMinor, cur)}</td><td className="num">{formatMoney(x.refundsMinor, cur)}</td></tr>)}</tbody></table></div></div></>}
      </>)}
    </Section>
  );
}

// =============================================================== pricing
function Pricing() {
  const act = useAct(); const { config } = useApp();
  const d = useApi<any>('/pricing');
  const [nw, setNw] = useState({ kind: 'SESSION', name: '', minutes: '60', price: '', dayType: 'ANY', customerType: 'ANY' });
  const cur = config?.venue.currency ?? 'ETB';
  const rules: any[] = d.data?.rules ?? [];
  async function edit(r: any, field: 'priceMinor' | 'active' | 'name', value: any) { if (await act(() => patch(`/pricing/${r.id}`, { [field]: value }), 'Saved — audited.')) d.reload(); }
  return (
    <Section title="Pricing" sub="Changes apply to new sales only; sessions already created keep the price they were sold at.">
      {(['SESSION', 'EXTENSION'] as const).map((kind) => (
        <div key={kind} className="card flush"><div style={{ padding: '14px 16px' }}><h2>{kind === 'SESSION' ? 'Session prices' : 'Extension prices'}</h2></div>
          <div className="tablewrap"><table className="t"><thead><tr><th>Name</th><th className="num">Minutes</th><th>Applies</th><th className="num">Price ({cur})</th><th>Active</th></tr></thead><tbody>
            {rules.filter((r) => r.kind === kind).map((r) => <tr key={r.id}><td><input className="input" style={{ minWidth: 140 }} defaultValue={r.name} onBlur={(e) => e.target.value !== r.name && edit(r, 'name', e.target.value)} /></td><td className="num">{r.durationMinutes}</td><td className="muted">{titleCase(r.dayType)} · {titleCase(r.customerType)}</td>
              <td className="num"><input className="input" style={{ width: 120, textAlign: 'right' }} defaultValue={(r.priceMinor / 100).toString()} inputMode="decimal" onBlur={(e) => { const m = toMinor(e.target.value); if (m !== null && m !== r.priceMinor) edit(r, 'priceMinor', m); }} /></td>
              <td><input type="checkbox" checked={r.active} onChange={(e) => edit(r, 'active', e.target.checked)} aria-label="Active" style={{ width: 22, height: 22 }} /></td></tr>)}</tbody></table></div></div>))}
      <div className="card col"><h2>Add price</h2><div className="row wrap">
        <Field label="Kind"><select className="input" value={nw.kind} onChange={(e) => setNw({ ...nw, kind: e.target.value })}><option value="SESSION">Session</option><option value="EXTENSION">Extension</option></select></Field>
        <Field label="Name"><input className="input" value={nw.name} onChange={(e) => setNw({ ...nw, name: e.target.value })} /></Field>
        <Field label="Minutes"><input className="input" style={{ width: 90 }} value={nw.minutes} onChange={(e) => setNw({ ...nw, minutes: e.target.value })} /></Field>
        <Field label={`Price (${cur})`}><input className="input" style={{ width: 120 }} value={nw.price} onChange={(e) => setNw({ ...nw, price: e.target.value })} /></Field>
        <Field label="Day type"><select className="input" value={nw.dayType} onChange={(e) => setNw({ ...nw, dayType: e.target.value })}>{['ANY', 'WEEKDAY', 'WEEKEND', 'HOLIDAY'].map((x) => <option key={x}>{x}</option>)}</select></Field>
        <Field label="Customer"><select className="input" value={nw.customerType} onChange={(e) => setNw({ ...nw, customerType: e.target.value })}>{['ANY', 'ADULT', 'CHILD'].map((x) => <option key={x}>{x}</option>)}</select></Field>
        <div style={{ alignSelf: 'end' }}><ActionButton className="btn primary" disabled={!nw.name || toMinor(nw.price) === null || !Number(nw.minutes)} onClick={async () => { if (await act(() => post('/pricing', { kind: nw.kind, name: nw.name, durationMinutes: Number(nw.minutes), priceMinor: toMinor(nw.price)!, dayType: nw.dayType, customerType: nw.customerType }), 'Price added.')) { setNw({ ...nw, name: '', price: '' }); d.reload(); } }}>Add</ActionButton></div></div></div>
    </Section>
  );
}

// =============================================================== devices
function Devices() {
  const act = useAct();
  const d = useApi<any>('/devices');
  const [f, setF] = useState({ name: '', deviceType: 'FRONT_DESK' });
  return (
    <Section title="Devices" sub="Every action is stamped with the device it came from.">
      <div className="card flush">{d.loading && !d.data ? <Loading /> : <div className="tablewrap"><table className="t"><thead><tr><th>Name</th><th>Type</th><th>Status</th><th>Last seen</th><th>Registered</th><th /></tr></thead><tbody>
        {d.data?.devices.map((x: any) => <tr key={x.id}><td><b>{x.name}</b></td><td>{titleCase(x.deviceType)}</td><td><span className={`badge lvl-${x.status === 'ACTIVE' ? 'normal' : 'red'}`}>{titleCase(x.status)}</span></td><td>{x.lastSeenAt ? fmtDateTime(x.lastSeenAt) : 'never'}</td><td>{fmtDate(x.registeredAt)}</td>
          <td><button className="btn small" onClick={async () => { if (await act(() => patch(`/devices/${x.id}`, { status: x.status === 'ACTIVE' ? 'DISABLED' : 'ACTIVE' }), 'Updated.')) d.reload(); }}>{x.status === 'ACTIVE' ? 'Disable' : 'Enable'}</button></td></tr>)}</tbody></table></div>}</div>
      <div className="card row wrap"><b>Register device</b><input className="input" style={{ maxWidth: 220 }} placeholder="e.g. RENTAL-DESK-02" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value.toUpperCase() })} /><select className="input" style={{ maxWidth: 180 }} value={f.deviceType} onChange={(e) => setF({ ...f, deviceType: e.target.value })}>{['FRONT_DESK', 'RENTAL_DESK', 'MANAGER', 'KIOSK', 'OTHER'].map((t) => <option key={t}>{t}</option>)}</select>
        <ActionButton className="btn primary" disabled={f.name.trim().length < 2} onClick={async () => { const r = await act(() => post('/devices', f), 'Device registered.'); if (r) { setF({ ...f, name: '' }); d.reload(); } }}>Register</ActionButton></div>
      <div className="hint">To attach a tablet to a registered device, sign in on it and use “Register this device” in the banner (managers), or an administrator can register it here and set it on the device.</div>
    </Section>
  );
}

// =============================================================== day close
function DayClose() {
  const act = useAct(); const { config } = useApp();
  const cur = config?.venue.currency;
  const [date, setDate] = useState(localToday());
  const p = useApi<any>(`/day-close/preview?date=${date}`);
  const past = useApi<any>('/day-closes');
  const [counted, setCounted] = useState(''); const [notes, setNotes] = useState(''); const [ack, setAck] = useState(false);
  const d = p.data;
  const countedMinor = toMinor(counted);
  const diff = d && countedMinor !== null ? countedMinor - d.expectedCashMinor : null;
  return (
    <Section title="Close day" sub="Checks the floor, then reconciles cash. The closing record is preserved and cannot be edited." right={<input type="date" className="input" style={{ width: 170 }} value={date} max={localToday()} onChange={(e) => e.target.value && setDate(e.target.value)} />}>
      {p.loading && !d ? <Loading /> : p.error ? <ErrorBox error={p.error} /> : d && <div className="card col">
        <div className="kpis"><Kpi label="Active sessions" value={d.checks.activeSessions} tone={d.checks.activeSessions ? 'red' : 'green'} /><Kpi label="Unreturned skates" value={d.checks.unreturnedSkates} tone={d.checks.unreturnedSkates ? 'red' : 'green'} /><Kpi label="Unresolved incidents" value={d.checks.unresolvedIncidents} tone={d.checks.unresolvedIncidents ? 'yellow' : 'green'} /><Kpi label="Unpaid sessions" value={d.checks.unpaidSessions} tone={d.checks.unpaidSessions ? 'red' : 'green'} /><Kpi label="Pending payments" value={d.checks.pendingPayments} tone={d.checks.pendingPayments ? 'red' : 'green'} /></div>
        <div className="kpis"><Kpi label="Expected cash" value={formatMoney(d.expectedCashMinor, cur)} /><div className="kpi"><div className="label">Counted cash ({cur})</div><input className="input big" inputMode="decimal" value={counted} onChange={(e) => setCounted(e.target.value)} disabled={d.alreadyClosed} /></div><Kpi label="Difference" value={diff === null ? '—' : formatMoney(diff, cur)} tone={diff === null ? undefined : diff === 0 ? 'green' : 'red'} /></div>
        {d.blockers.length > 0 && <div className="banner red"><Icon n="stop" />Cannot close yet: {d.blockers.join(', ')}.</div>}
        {d.warnings.length > 0 && <label className="check"><input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} /><span>Close anyway with: {d.warnings.join(', ')}</span></label>}
        <Field label={`Notes${diff ? ' (required — explain the difference)' : ''}`}><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        {d.alreadyClosed ? <div className="banner ok"><Icon n="lock" />DAY CLOSED {fmtDateTime(d.closedAt)}</div> :
          <ActionButton className="btn primary big" disabled={d.blockers.length > 0 || countedMinor === null || (d.warnings.length > 0 && !ack) || (diff !== 0 && !notes.trim())} onClick={async () => { if (await act(() => post('/day-close', { date, countedCashMinor: countedMinor, notes: notes || undefined, acknowledgeWarnings: ack }), 'Day closed.')) { p.reload(); past.reload(); } }}><Icon n="lock" /> Close day</ActionButton>}
      </div>}
      {past.data?.closes.length > 0 && <div className="card flush"><div style={{ padding: '14px 16px' }}><h2>Previous closes</h2></div><div className="tablewrap"><table className="t"><thead><tr><th>Date</th><th className="num">Expected</th><th className="num">Counted</th><th className="num">Difference</th><th>Notes</th><th>Closed</th></tr></thead><tbody>{past.data.closes.map((c: any) => <tr key={c.id}><td>{fmtDate(c.localDate)}</td><td className="num">{formatMoney(c.expectedCashMinor, cur)}</td><td className="num">{formatMoney(c.countedCashMinor, cur)}</td><td className="num">{formatMoney(c.differenceMinor, cur)}</td><td>{c.notes ?? ''}</td><td>{fmtDateTime(c.closedAt)}</td></tr>)}</tbody></table></div></div>}
    </Section>
  );
}

// =============================================================== audit
function Audit() {
  const [action, setAction] = useState(''); const entity = '';
  const [open, setOpen] = useState<number | null>(null);
  const q = useMemo(() => `/audit?limit=200${action ? `&action=${encodeURIComponent(action)}` : ''}${entity ? `&entityType=${encodeURIComponent(entity)}` : ''}`, [action, entity]);
  const d = useApi<any>(q);
  const groups = ['', 'session.', 'payment.', 'customer.', 'equipment.', 'incident.', 'staff.', 'settings.', 'pricing.', 'capacity.', 'security.', 'auth.', 'photo.'];
  return (
    <Section title="Audit log" sub="Every important business action: who, what, when, from which device. Append-only.">
      <div className="chips">{groups.map((g) => <button key={g} className={`chip ${action === g ? 'on' : ''}`} onClick={() => setAction(g)}>{g ? g.replace('.', '') : 'All'}</button>)}</div>
      <div className="card flush">{d.loading && !d.data ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : !d.data?.entries.length ? <Empty>Nothing recorded.</Empty> :
        <div className="tablewrap"><table className="t"><thead><tr><th>Time</th><th>Who</th><th>Action</th><th>Entity</th><th>Device</th><th>Reason</th><th /></tr></thead><tbody>
          {d.data.entries.map((e: any) => [<tr key={e.id} className="click" onClick={() => setOpen(open === e.id ? null : e.id)}><td className="nowrap">{fmtDateTime(e.createdAt)}</td><td>{e.actorName ?? 'system'}</td><td><b>{e.action}</b></td><td className="muted">{e.entityType}{e.entityId ? ` ${String(e.entityId).slice(0, 8)}` : ''}</td><td>{e.deviceName ?? '—'}</td><td>{e.reason ?? ''}</td><td className="muted">{(e.beforeData || e.afterData) ? '▾' : ''}</td></tr>,
            open === e.id && <tr key={e.id + 'x'}><td colSpan={7}><div className="row top wrap small">{e.beforeData && <pre style={{ margin: 0, flex: 1 }}><b>before</b>{'\n'}{JSON.stringify(e.beforeData, null, 2)}</pre>}{e.afterData && <pre style={{ margin: 0, flex: 1 }}><b>after</b>{'\n'}{JSON.stringify(e.afterData, null, 2)}</pre>}<span className="muted">request {e.requestId}{e.ip ? ` · ${e.ip}` : ''}</span></div></td></tr>])}</tbody></table></div>}</div>
    </Section>
  );
}
