import { useEffect, useState, type FormEvent } from 'react';
import { ApiError, auth, post } from './api';
import { useApp } from './state';
import { ActionButton, Field, Icon, Loading, Logo, ToastHost } from './components/ui';
import { Home } from './staff/Home';
import { CheckIn } from './staff/CheckIn';
import { Search } from './staff/Search';
import { History } from './staff/History';
import { Equipment } from './staff/Equipment';
import { Incidents, IncidentForm, Emergency } from './staff/Incidents';
import { Admin, MANAGEMENT_PERMS } from './admin/Admin';
import { queue } from './offline';

function useHash() {
  const [h, setH] = useState(location.hash.slice(1) || '/staff/home');
  useEffect(() => { const f = () => setH(location.hash.slice(1) || '/staff/home'); window.addEventListener('hashchange', f); return () => window.removeEventListener('hashchange', f); }, []);
  return [h, (to: string) => { location.hash = to; }] as const;
}

export function App() {
  const { me, booting } = useApp();
  if (booting) return <div className="login"><Loading /></div>;
  return <><ToastHost />{me ? <Shell /> : <Login />}</>;
}

function Login() {
  const { login, toast } = useApp();
  const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function submit(e: FormEvent) {
    e.preventDefault(); setBusy(true); setErr(null);
    try { await login(email.trim(), password); } catch (x) { const m = x instanceof ApiError ? x.message : 'Could not sign in.'; setErr(m); toast('error', m); } finally { setBusy(false); }
  }
  return (
    <div className="login"><form className="card col" onSubmit={submit}>
      <div className="row"><div style={{ width: 40 }}><Logo /></div><div><h1>Light Skate</h1><div className="muted small">Venue operations</div></div></div>
      <Field label="Email"><input className="input" type="email" autoComplete="username" autoFocus value={email} onChange={(e) => setEmail(e.target.value)} required /></Field>
      <Field label="Password"><input className="input" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></Field>
      {err && <div className="err" role="alert">{err}</div>}
      <button className="btn primary big" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
    </form></div>
  );
}

function Shell() {
  const { me, config, can, logout, live, queued } = useApp();
  const [hash, nav] = useHash();
  const [emergency, setEmergency] = useState(false);
  const [incident, setIncident] = useState(false);
  const [devPrompt, setDevPrompt] = useState(false);
  const mode = hash.startsWith('/admin') ? 'admin' : 'staff';
  const page = hash.split('?')[0].split('/')[2] ?? 'home';
  const query = new URLSearchParams(hash.split('?')[1] ?? '');
  const adminAllowed = MANAGEMENT_PERMS.some((x) => can(x));

  const staffTabs = [
    ['home', 'Live', 'home', true], ['checkin', 'Check-in', 'plus', can('session.create')], ['search', 'Customers', 'search', can('customer.read') || can('customer.create')],
    ['history', 'History', 'list', can('visit.read')], ['equipment', 'Equipment', 'skate', can('equipment.read')], ['incidents', 'Incidents', 'flag', can('incident.create') || can('incident.read')],
  ] as const;

  return (
    <>
      <div className="topbar">
        <div className="brand"><div style={{ width: 28 }}><Logo /></div>Light Skate</div>
        <span className="venue">{config?.venue.name}</span>
        <span className="spacer" />
        {queued > 0 && <span className="pill lvl-yellow" title="Actions waiting to sync"><Icon n="clock" />{queued} queued</span>}
        <span className="pill" title={live === 'live' ? 'Real-time updates on' : live === 'connecting' ? 'Connecting…' : 'Offline — showing last known state; timers keep running'}><span className={`dot ${live}`} />{live === 'live' ? 'Live' : live === 'connecting' ? 'Connecting' : 'Offline'}</span>
        {adminAllowed && <button className="btn small" onClick={() => nav(mode === 'admin' ? '/staff/home' : '/admin/overview')}>{mode === 'admin' ? 'Staff view' : 'Admin'}</button>}
        {can('incident.create') && <button className="btn small" onClick={() => setIncident(true)} title="Report an incident"><Icon n="flag" /><span className="hide-sm"> Incident</span></button>}
        <button className="btn small emg" onClick={() => setEmergency(true)} aria-label="Emergency information"><Icon n="alert" /> Emergency</button>
        <div className="row gap-s"><span className="small muted" title={me?.email}>{me?.fullName}</span><button className="btn small ghost" onClick={logout}>Sign out</button></div>
      </div>
      {can('device.manage') && !auth.deviceId && <div className="banner yellow" style={{ borderRadius: 0 }}><Icon n="warn" />This browser is not a registered device, so actions are not attributed to a device. <button className="btn small" onClick={() => setDevPrompt(true)}>Register this device</button></div>}
      {mode === 'staff' ? (<>
        <nav className="tabs" aria-label="Staff navigation">{staffTabs.filter((t) => t[3]).map(([k, l, ic]) => <button key={k} className={`tab ${page === k ? 'active' : ''}`} onClick={() => nav(`/staff/${k}`)}><Icon n={ic} size={18} />{l}</button>)}</nav>
        {page === 'home' && <Home go={(r) => nav(`/staff/${r}`)} />}
        {page === 'checkin' && <CheckIn key={query.get('session') ?? 'new'} resumeSessionId={query.get('session') ?? undefined} done={() => nav('/staff/home')} />}
        {page === 'search' && <Search go={(r) => nav(`/staff/${r}`)} />}
        {page === 'history' && <History />}
        {page === 'equipment' && <Equipment />}
        {page === 'incidents' && <Incidents />}
      </>) : <Admin page={page} nav={(p) => nav(`/admin/${p}`)} />}
      {emergency && <Emergency onClose={() => setEmergency(false)} />}
      {incident && <IncidentForm onClose={() => setIncident(false)} />}
      {devPrompt && <RegisterDevice onClose={() => setDevPrompt(false)} />}
      <span className="hide">{queue.length}</span>
    </>
  );
}

function RegisterDevice({ onClose }: { onClose: () => void }) {
  const { toast } = useApp();
  const [name, setName] = useState(''); const [type, setType] = useState('FRONT_DESK');
  return (
    <div className="scrim"><div className="modal sm"><header><h2>Register this device</h2></header><div className="body col">
      <Field label="Device name" hint="e.g. FRONT-DESK-01"><input className="input" value={name} onChange={(e) => setName(e.target.value.toUpperCase())} autoFocus /></Field>
      <Field label="Type"><select className="input" value={type} onChange={(e) => setType(e.target.value)}>{['FRONT_DESK', 'RENTAL_DESK', 'MANAGER', 'KIOSK', 'OTHER'].map((t) => <option key={t}>{t}</option>)}</select></Field>
    </div><footer><button className="btn" onClick={onClose}>Not now</button><ActionButton className="btn primary" disabled={name.trim().length < 2} onClick={async () => {
      try { const d = await post('/devices', { name, deviceType: type }); auth.setDevice(d.id); toast('ok', `Registered as ${name}.`); onClose(); location.reload(); } catch (e) { toast('error', e instanceof ApiError ? e.message : 'Failed'); }
    }}>Register</ActionButton></footer></div></div>
  );
}
