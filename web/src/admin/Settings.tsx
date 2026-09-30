import { useEffect, useState } from 'react';
import { get, post, put } from '../api';
import { useApp } from '../state';
import { ActionButton, ErrorBox, Field, Icon, Loading } from '../components/ui';
import { useAct } from '../components/actions';

/** Venue policy. Everything here is enforced by the backend; the UI only edits it. Saves are validated + audited. */
export function Settings() {
  const { can, refreshConfig } = useApp();
  const act = useAct();
  const [s, setS] = useState<any>(null);
  const [orig, setOrig] = useState<any>(null);
  const [cap, setCap] = useState(''); const [capReason, setCapReason] = useState('');
  const [waiver, setWaiver] = useState<any>(null); const [newWaiver, setNewWaiver] = useState({ title: '', body: '' });
  const [err, setErr] = useState<string | null>(null);
  async function load() {
    try {
      if (can('settings.manage')) { const r = await get('/settings'); setS(structuredClone(r.settings)); setOrig(r.settings); setCap(String(r.maxCapacity)); setWaiver((await get('/waivers/current')).waiver); }
      else { const c = await get('/config'); setCap(String(c.maxCapacity)); setS({}); }
    } catch (e: any) { setErr(e.message); }
  }
  useEffect(() => { load(); /* eslint-disable-next-line */ }, []);
  if (err) return <div className="page"><ErrorBox error={{ message: err }} /></div>;
  if (!s) return <div className="page"><Loading /></div>;
  const set = (k: string, v: any) => setS({ ...s, [k]: v });
  const dirty = orig ? Object.keys(s).filter((k) => JSON.stringify(s[k]) !== JSON.stringify(orig[k])) : [];

  async function save() {
    const patch = Object.fromEntries(dirty.map((k) => [k, s[k]]));
    const r = await act(() => put('/settings', patch), 'Settings saved (audited).');
    if (r) { setOrig(structuredClone(r.settings)); setS(structuredClone(r.settings)); refreshConfig(); }
  }
  const num = (v: string) => (v === '' ? 0 : Number(v));

  return (
    <div className="page col">
      <div className="row between wrap"><div><h1>Capacity & settings</h1><div className="muted">Business rules live here, not in the screens. The server enforces them.</div></div>
        {can('settings.manage') && <ActionButton className="btn primary big" disabled={!dirty.length} onClick={save}>Save changes{dirty.length ? ` (${dirty.length})` : ''}</ActionButton>}</div>

      {can('capacity.manage') && <div className="card col"><h2>Venue capacity</h2>
        <div className="row wrap"><Field label="Maximum people inside"><input className="input" style={{ width: 140 }} inputMode="numeric" value={cap} onChange={(e) => setCap(e.target.value)} /></Field><div className="grow"><Field label="Reason (recorded)"><input className="input" value={capReason} onChange={(e) => setCapReason(e.target.value)} /></Field></div>
          <div style={{ alignSelf: 'end' }}><ActionButton className="btn primary" disabled={!/^\d+$/.test(cap)} onClick={async () => { if (await act(() => put('/capacity', { maxCapacity: Number(cap), reason: capReason || undefined }), 'Capacity updated.')) { setCapReason(''); refreshConfig(); } }}>Update capacity</ActionButton></div></div>
        <div className="hint">New sessions are refused by the server once this many people are inside (occupancy is derived from live sessions).</div></div>}

      {can('settings.manage') && s.pause && <>
        <div className="card col"><h2>Timers & warnings</h2>
          <div className="row wrap">{s.warnings.map((w: any, i: number) => <div key={i} className="row"><Field label={`Warning ${i + 1} (minutes left)`}><input className="input" style={{ width: 110 }} value={w.minutes} onChange={(e) => set('warnings', s.warnings.map((x: any, j: number) => j === i ? { ...x, minutes: num(e.target.value) } : x))} /></Field>
            <Field label="Colour"><select className="input" value={w.level} onChange={(e) => set('warnings', s.warnings.map((x: any, j: number) => j === i ? { ...x, level: e.target.value } : x))}><option>YELLOW</option><option>ORANGE</option><option>RED</option></select></Field></div>)}</div>
          <div className="row wrap"><Field label="Mark “ending soon” at (minutes left)"><input className="input" style={{ width: 140 }} value={s.expiringMinutes} onChange={(e) => set('expiringMinutes', num(e.target.value))} /></Field>
            <Field label="Early-exit grace (seconds)" hint="Ending within this of the end time counts as completed"><input className="input" style={{ width: 140 }} value={s.earlyExitGraceSeconds} onChange={(e) => set('earlyExitGraceSeconds', num(e.target.value))} /></Field>
            <Field label="Auto no-show after (minutes, 0 = off)"><input className="input" style={{ width: 140 }} value={s.noShowMinutes} onChange={(e) => set('noShowMinutes', num(e.target.value))} /></Field></div></div>

        <div className="card col"><h2>Pausing & extensions</h2>
          <label className="check"><input type="checkbox" checked={s.pause.enabled} onChange={(e) => set('pause', { ...s.pause, enabled: e.target.checked })} /><span>Allow pausing sessions</span></label>
          <label className="check"><input type="checkbox" checked={s.pause.countsTowardTime} onChange={(e) => set('pause', { ...s.pause, countsTowardTime: e.target.checked })} /><span>Paused time counts toward the paid session<br /><span className="hint">Off (recommended): the clock stops while paused and the end time moves out. Applies to sessions started after you save.</span></span></label>
          <Field label="Extension options (minutes, comma separated)"><input className="input" style={{ maxWidth: 300 }} value={s.extensionOptionsMinutes.join(', ')} onChange={(e) => set('extensionOptionsMinutes', e.target.value.split(',').map((x) => Number(x.trim())).filter((n) => n > 0))} /></Field></div>

        <div className="card col"><h2>Check-in</h2>
          <label className="check"><input type="checkbox" checked={s.waiverRequired} onChange={(e) => set('waiverRequired', e.target.checked)} /><span>Require the waiver before skating</span></label>
          <Field label="Customer photo"><select className="input" style={{ maxWidth: 320 }} value={s.photoCapture} onChange={(e) => set('photoCapture', e.target.value)}><option value="NEW_CUSTOMER">Capture for new customers (and when missing)</option><option value="EVERY_VISIT">Capture at every visit</option><option value="NEVER">Never prompt for a photo</option></select></Field>
          <label className="check"><input type="checkbox" checked={s.wristbands.enabled} onChange={(e) => set('wristbands', { ...s.wristbands, enabled: e.target.checked })} /><span>Use wristbands (colour per session)</span></label>
          {s.wristbands.enabled && <Field label="Wristband colours"><input className="input" style={{ maxWidth: 320 }} value={s.wristbands.colors.join(', ')} onChange={(e) => set('wristbands', { ...s.wristbands, colors: e.target.value.split(',').map((x) => x.trim().toUpperCase()).filter(Boolean) })} /></Field>}
          <label className="check"><input type="checkbox" checked={s.equipmentRequiredForStart} onChange={(e) => set('equipmentRequiredForStart', e.target.checked)} /><span>Require rental skates to be issued before a session can start</span></label>
          <label className="check"><input type="checkbox" checked={s.inspectOnReturn} onChange={(e) => set('inspectOnReturn', e.target.checked)} /><span>Returned skates need an inspection before they can be issued again</span></label>
          <label className="check"><input type="checkbox" checked={s.enforceOperatingHours} onChange={(e) => set('enforceOperatingHours', e.target.checked)} /><span>Block new sessions outside operating hours</span></label>
          <Field label="Minor age limit (years)"><input className="input" style={{ width: 120 }} value={s.minorAgeYears} onChange={(e) => set('minorAgeYears', num(e.target.value))} /></Field></div>

        <div className="card col"><h2>Payment methods</h2>{s.paymentMethods.map((m: any, i: number) => <div key={m.code} className="row wrap"><label className="check" style={{ minWidth: 200 }}><input type="checkbox" checked={m.enabled} onChange={(e) => set('paymentMethods', s.paymentMethods.map((x: any, j: number) => j === i ? { ...x, enabled: e.target.checked } : x))} /><b>{m.label}</b></label>
          <label className="check"><input type="checkbox" checked={m.requiresReference} onChange={(e) => set('paymentMethods', s.paymentMethods.map((x: any, j: number) => j === i ? { ...x, requiresReference: e.target.checked } : x))} /><span>needs receipt / reference number</span></label></div>)}
          <div className="hint">All methods are recorded manually today. Automated providers (Telebirr, bank, card) plug into the payment provider interface later.</div></div>

        <div className="card col"><h2>Data retention</h2><div className="row wrap">
          <Field label="Profile photo (days, empty = while profile is active)"><input className="input" style={{ width: 160 }} value={s.retention.profilePhotoDays ?? ''} onChange={(e) => set('retention', { ...s.retention, profilePhotoDays: e.target.value ? num(e.target.value) : null })} /></Field>
          <Field label="Visit photo (days)"><input className="input" style={{ width: 160 }} value={s.retention.visitPhotoDays ?? ''} onChange={(e) => set('retention', { ...s.retention, visitPhotoDays: e.target.value ? num(e.target.value) : null })} /></Field>
          <Field label="Incident photos (days)"><input className="input" style={{ width: 160 }} value={s.retention.incidentAttachmentDays ?? ''} onChange={(e) => set('retention', { ...s.retention, incidentAttachmentDays: e.target.value ? num(e.target.value) : null })} /></Field></div>
          <div className="hint">Applies to photos captured after the change. A background job deletes expired files. Financial and audit records are never deleted by these settings.</div></div>

        <div className="card col"><h2>Emergency information</h2><div className="row wrap">{(['ambulance', 'police', 'fire', 'venueContact', 'manager'] as const).map((k) => <Field key={k} label={k === 'venueContact' ? 'Venue emergency contact' : k[0].toUpperCase() + k.slice(1)}><input className="input" style={{ width: 200 }} value={s.emergency[k]} onChange={(e) => set('emergency', { ...s.emergency, [k]: e.target.value })} /></Field>)}</div>
          <Field label="Venue address"><input className="input" value={s.emergency.address} onChange={(e) => set('emergency', { ...s.emergency, address: e.target.value })} /></Field>
          <Field label="First-aid information"><textarea className="input" rows={2} value={s.emergency.firstAid} onChange={(e) => set('emergency', { ...s.emergency, firstAid: e.target.value })} /></Field></div>

        <div className="card col"><h2>Waiver / rules</h2>{waiver && <div className="muted">Current: version {waiver.version} — “{waiver.title}”. Publishing a new version never edits old ones; customers will be asked to accept the new version at their next visit.</div>}
          {can('waiver.manage') && <><Field label="New version title"><input className="input" value={newWaiver.title} onChange={(e) => setNewWaiver({ ...newWaiver, title: e.target.value })} /></Field>
            <Field label="New version text"><textarea className="input" rows={6} value={newWaiver.body} onChange={(e) => setNewWaiver({ ...newWaiver, body: e.target.value })} placeholder={waiver?.body} /></Field>
            <ActionButton className="btn" disabled={newWaiver.title.trim().length < 3 || newWaiver.body.trim().length < 20} onClick={async () => { if (await act(() => post('/waivers/versions', newWaiver), 'New waiver version published.')) { setNewWaiver({ title: '', body: '' }); load(); } }}><Icon n="shield" /> Publish new version</ActionButton></>}
          <div className="hint">Have the wording reviewed by local legal counsel; the shipped text is a template only.</div></div>
      </>}
    </div>
  );
}
