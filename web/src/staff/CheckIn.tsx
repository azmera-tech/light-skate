import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ApiError, get, newKey, post } from '../api';
import { useApp } from '../state';
import { formatMoney, fmtDate, phoneDisplay, toMinor } from '../format';
import { ActionButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Photo } from '../components/ui';
import { Camera } from '../components/Camera';
import { SignaturePad } from '../components/SignaturePad';

type Step = 'customer' | 'details' | 'photo' | 'waiver' | 'session' | 'payment' | 'start';
const STEP_LABEL: [Step, string][] = [['customer', 'Customer'], ['photo', 'Photo'], ['waiver', 'Waiver'], ['session', 'Session'], ['payment', 'Payment'], ['start', 'Start']];

/** Keeps one idempotency key per (action, exact body): a retry of the same request reuses it, an edited request gets a new one. */
function useIdem() {
  const m = useRef(new Map<string, { body: string; key: string }>());
  return (name: string, body: unknown) => {
    const b = JSON.stringify(body ?? null);
    const cur = m.current.get(name);
    if (cur && cur.body === b) return cur.key;
    const key = newKey(); m.current.set(name, { body: b, key }); return key;
  };
}

export function CheckIn({ resumeSessionId, done }: { resumeSessionId?: string; done: () => void }) {
  const { config, can, toast } = useApp();
  const idem = useIdem();
  const [step, setStep] = useState<Step>('customer');
  const [phone, setPhone] = useState('');
  const [matches, setMatches] = useState<any[] | null>(null);
  const [normalized, setNormalized] = useState<string | null>(null);
  const [customer, setCustomer] = useState<any>(null);   // full profile
  const [isNew, setIsNew] = useState(false);
  const [visitId, setVisitId] = useState<string | null>(null);
  const [session, setSession] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [dup, setDup] = useState<any[] | null>(null);
  const [photoDone, setPhotoDone] = useState(false);
  const [booting, setBooting] = useState(!!resumeSessionId);
  const settings = config!.settings;
  const cur = config!.venue.currency;

  const fail = (e: unknown) => { const m = e instanceof ApiError ? e.message : 'Something went wrong.'; setError(m); toast('error', m); };

  // ---- resume an interrupted check-in (paid/pending session that has not started)
  useEffect(() => {
    if (!resumeSessionId) return;
    (async () => {
      try {
        const d = await get(`/sessions/${resumeSessionId}`);
        const c = await get(`/customers/${d.session.customerId}`);
        setCustomer(c); setVisitId(d.session.visitId); setSession(d.session); setPhotoDone(true);
        setStep(d.session.dueMinor - d.session.paidMinor > 0 ? 'payment' : 'start');
      } catch (e) { fail(e); } finally { setBooting(false); }
    })();
    // eslint-disable-next-line
  }, [resumeSessionId]);

  // ---- phone search (debounced; server rate-limited)
  useEffect(() => {
    if (step !== 'customer') return;
    const digits = phone.replace(/\D/g, '');
    if (digits.length < 4) { setMatches(null); setNormalized(null); return; }
    const t = setTimeout(async () => {
      try { const r = await get(`/customers?q=${encodeURIComponent(phone)}&limit=8`); setMatches(r.customers); setNormalized(r.normalizedPhone); }
      catch (e) { if (e instanceof ApiError && e.status === 429) toast('info', e.message); }
    }, 250);
    return () => clearTimeout(t);
  }, [phone, step, toast]);

  const nextAfterCustomer = useCallback(async (c: any, newCustomer: boolean) => {
    setCustomer(c); setIsNew(newCustomer); setError(null);
    const v = await post('/visits', { customerId: c.id }, { key: newKey() });
    setVisitId(v.id);
    const needsPhoto = settings.photoCapture === 'EVERY_VISIT' || (settings.photoCapture === 'NEW_CUSTOMER' && (newCustomer || !c.photoId));
    if (needsPhoto && can('customer.update')) setStep('photo');
    else if (settings.waiverRequired && !c.waiver?.accepted) setStep('waiver');
    else setStep('session');
  }, [settings, can]);

  async function pickExisting(m: any) {
    try { const c = await get(`/customers/${m.id}`); await nextAfterCustomer(c, false); } catch (e) { fail(e); }
  }

  if (booting) return <div className="page"><Loading /></div>;
  const stepIdx = STEP_LABEL.findIndex(([s]) => s === (step === 'details' ? 'customer' : step));

  return (
    <div className="page narrow touch col">
      <div className="row between"><h1>{customer ? `Check-in: ${customer.fullName}` : 'New check-in'}</h1><button className="btn ghost" onClick={done}>Cancel</button></div>
      <div className="steps" aria-label="Progress">{STEP_LABEL.map(([s, l], i) => <span key={s} className={`step ${i < stepIdx ? 'done' : i === stepIdx ? 'on' : ''}`}>{i < stepIdx ? '✓ ' : ''}{l}</span>)}</div>
      {error && <ErrorBox error={{ message: error }} />}

      {/* ---------------- customer ---------------- */}
      {step === 'customer' && (
        <div className="card col">
          <Field label="Customer phone number" hint="Any format works: 0912345678, +251912345678 …">
            <input className="input big" inputMode="tel" autoFocus placeholder="09…" value={phone} onChange={(e) => setPhone(e.target.value)} aria-label="Customer phone number" />
          </Field>
          {matches && matches.length > 0 && <div className="col gap-s"><b>Existing customer{matches.length > 1 ? 's' : ''} found — tap to continue</b>
            {matches.map((m) => (
              <button key={m.id} className="person" onClick={() => pickExisting(m)}>
                <Photo id={m.photoId} name={m.fullName} /><div className="grow"><b>{m.fullName}</b><div className="muted small">{phoneDisplay(m.phoneE164)} · {m.customerCode}</div>
                  <div className="muted small">{m.visitCount} visit{m.visitCount === 1 ? '' : 's'}{m.lastVisitAt ? ` · last ${fmtDate(m.lastVisitAt)}` : ''}</div></div>
                {m.isActive ? <span className="badge lvl-normal">Skating now</span> : <Icon n="check" />}
              </button>))}
          </div>}
          {normalized && matches && matches.length === 0 && <div className="banner info"><Icon n="user" />No existing customer with this number.</div>}
          {!normalized && phone.replace(/\D/g, '').length >= 9 && <div className="banner yellow" role="alert"><Icon n="warn" />That doesn't look like a valid phone number. Check the digits (e.g. 0912 345 678).</div>}
          {can('customer.create') && <button className="btn primary big" disabled={!normalized} onClick={() => setStep('details')}><Icon n="plus" size={20} /> Register new customer{normalized ? ` (${phoneDisplay(normalized)})` : ''}</button>}
        </div>
      )}

      {/* ---------------- details ---------------- */}
      {step === 'details' && <Details phone={phone} idem={idem} onBack={() => setStep('customer')} onError={fail}
        onCreated={(c: any) => nextAfterCustomer(c, true).catch(fail)} onDuplicates={setDup} settings={settings} />}
      {dup && <Modal title="Possible existing customer found." onClose={() => setDup(null)}>
        <div className="col"><p className="muted">A customer with this phone number is already registered. Is this the same person?</p>
          {dup.map((m) => <button key={m.id} className="person" onClick={async () => { setDup(null); await pickExisting(m); }}><Photo id={m.photoId} name={m.fullName} /><div className="grow"><b>{m.fullName}</b><div className="muted small">{phoneDisplay(m.phoneE164)} · {m.customerCode}{m.lastVisitAt ? ` · last visit ${fmtDate(m.lastVisitAt)}` : ''}</div></div><span className="btn small primary">Same person</span></button>)}
          <div className="hint">Parents often register several children with one number. If this is a different person, register them as a new customer.</div>
          <button className="btn" onClick={() => { setDup(null); (window as any).__confirmDistinct?.(); }}>Different person — create new customer</button></div>
      </Modal>}

      {/* ---------------- photo ---------------- */}
      {step === 'photo' && customer && visitId && (
        <div className="card col">
          <h2>{isNew ? 'Take a photo of the customer' : 'Confirm identity'}</h2>
          {!isNew && customer.photoId && <div className="row"><Photo id={customer.photoId} name={customer.fullName} size="lg" /><div><b>{customer.fullName}</b><div className="muted">{phoneDisplay(customer.phoneE164)}</div></div></div>}
          <div className="hint">The photo helps staff recognise people on the rink. It is stored privately and deleted according to the venue's retention policy.</div>
          {!photoDone ? <Camera onSkip={() => proceedFromPhoto()} onCapture={async (blob) => {
            try {
              const purpose = isNew || !customer.photoId ? 'PROFILE' : 'VISIT';
              await post(`/customers/${customer.id}/photos?purpose=${purpose}&visitId=${visitId}`, blob, { contentType: 'image/jpeg', key: newKey() });
              toast('ok', 'Photo saved.'); setPhotoDone(true); proceedFromPhoto();
            } catch (e) { fail(e); }
          }} /> : <button className="btn primary big" onClick={() => proceedFromPhoto()}>Continue</button>}
          {!isNew && customer.photoId && !photoDone && <button className="btn big" onClick={() => setPhotoDone(true)}>Yes, it is them — keep current photo</button>}
        </div>
      )}

      {/* ---------------- waiver ---------------- */}
      {step === 'waiver' && customer && <Waiver customer={customer} visitId={visitId} idem={idem} onError={fail} onAccepted={async () => { setCustomer(await get(`/customers/${customer.id}`)); setStep('session'); }} />}

      {/* ---------------- session ---------------- */}
      {step === 'session' && customer && visitId && <ChooseSession customer={customer} visitId={visitId} idem={idem} onError={fail} currency={cur}
        onCreated={(s: any) => { setSession(s); setStep(s.status === 'READY' ? 'start' : 'payment'); }} />}

      {/* ---------------- payment ---------------- */}
      {step === 'payment' && session && <Payment session={session} idem={idem} onError={fail} currency={cur} onPaid={(s: any) => { setSession(s); setStep(s.status === 'READY' ? 'start' : 'payment'); }} />}

      {/* ---------------- start ---------------- */}
      {step === 'start' && session && customer && <StartStep session={session} customer={customer} onError={fail} onStarted={() => { toast('ok', `${customer.fullName} is skating.`); done(); }} />}
    </div>
  );

  function proceedFromPhoto() {
    if (settings.waiverRequired && !customer.waiver?.accepted) setStep('waiver'); else setStep('session');
  }
}

// ======================================================================= details
function Details({ phone, idem, onCreated, onDuplicates, onBack, onError, settings }: any) {
  const [f, setF] = useState({ fullName: '', dob: '', email: '', ecName: '', ecPhone: '', notes: '' });
  const [phoneVal, setPhoneVal] = useState(phone);
  const set = (k: string, v: string) => setF((p) => ({ ...p, [k]: v }));
  const minor = f.dob && (() => { const d = new Date(f.dob); const cut = new Date(); cut.setFullYear(cut.getFullYear() - settings.minorAgeYears); return d > cut; })();
  const body = (confirmDistinct?: boolean) => ({
    fullName: f.fullName.trim(), phone: phoneVal, dateOfBirth: f.dob || undefined, email: f.email.trim() || undefined, notes: f.notes.trim() || undefined,
    emergencyContact: f.ecName.trim() && f.ecPhone.trim() ? { name: f.ecName.trim(), phone: f.ecPhone.trim(), isGuardian: !!minor } : undefined, confirmDistinct,
  });
  async function submit(confirmDistinct?: boolean) {
    const b = body(confirmDistinct);
    try { const r = await post('/customers', b, { key: idem('customer', b) }); onCreated(await get(`/customers/${r.id}`)); }
    catch (e) {
      if (e instanceof ApiError && e.code === 'POSSIBLE_DUPLICATE') { (window as any).__confirmDistinct = () => submit(true); onDuplicates(e.details?.candidates ?? []); }
      else onError(e);
    }
  }
  return (
    <div className="card col">
      <h2>New customer</h2>
      <div className="row wrap">
        <div className="grow"><Field label="Full name"><input className="input" autoFocus value={f.fullName} onChange={(e) => set('fullName', e.target.value)} /></Field></div>
        <div className="grow"><Field label="Phone"><input className="input" inputMode="tel" value={phoneVal} onChange={(e) => setPhoneVal(e.target.value)} /></Field></div>
      </div>
      <div className="row wrap">
        <div className="grow"><Field label="Date of birth (optional)" hint="Used for child pricing and the guardian workflow"><input className="input" type="date" value={f.dob} max={new Date().toISOString().slice(0, 10)} onChange={(e) => set('dob', e.target.value)} /></Field></div>
        <div className="grow"><Field label="Email (optional)"><input className="input" type="email" value={f.email} onChange={(e) => set('email', e.target.value)} /></Field></div>
      </div>
      {minor && <div className="banner info"><Icon n="shield" />This customer is a minor. A guardian must accept the waiver. Add the guardian as the emergency contact below.</div>}
      <div className="row wrap">
        <div className="grow"><Field label={minor ? 'Guardian name' : 'Emergency contact name (optional)'}><input className="input" value={f.ecName} onChange={(e) => set('ecName', e.target.value)} /></Field></div>
        <div className="grow"><Field label={minor ? 'Guardian phone' : 'Emergency contact phone'}><input className="input" inputMode="tel" value={f.ecPhone} onChange={(e) => set('ecPhone', e.target.value)} /></Field></div>
      </div>
      <div className="row"><button className="btn" onClick={onBack}>Back</button><ActionButton className="btn primary big grow" disabled={f.fullName.trim().length < 2} onClick={() => submit()}>Save & continue</ActionButton></div>
    </div>
  );
}

// ======================================================================= waiver
function Waiver({ customer, visitId, idem, onAccepted, onError }: any) {
  const [w, setW] = useState<any>(null);
  const [agree, setAgree] = useState(false);
  const [sig, setSig] = useState<string | null>(null);
  const [g, setG] = useState({ name: '', phone: '' });
  const minor = customer.isMinor;
  useEffect(() => { get('/waivers/current').then((r) => setW(r.waiver)).catch(onError); }, []); // eslint-disable-line
  if (!w) return <div className="card"><Loading /></div>;
  const body = { waiverVersionId: w.id, visitId, signatureData: sig ?? undefined, guardianName: minor ? g.name : undefined, guardianPhone: minor ? g.phone : undefined };
  return (
    <div className="card col">
      <h2>{w.title}</h2><div className="muted small">Version {w.version}</div>
      <div className="waiver" tabIndex={0}>{w.body}</div>
      {minor && <div className="col"><div className="banner info"><Icon n="shield" />{customer.fullName} is a minor — a parent or guardian must accept.</div>
        <div className="row wrap"><div className="grow"><Field label="Guardian full name"><input className="input" value={g.name} onChange={(e) => setG({ ...g, name: e.target.value })} /></Field></div>
          <div className="grow"><Field label="Guardian phone"><input className="input" inputMode="tel" value={g.phone} onChange={(e) => setG({ ...g, phone: e.target.value })} /></Field></div></div></div>}
      <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} /><span>{minor ? 'The guardian has read and accepts' : 'The customer has read and accepts'} the skating rules, assumption of risk and personal-data notice.</span></label>
      <Field label="Signature (optional)"><SignaturePad onChange={setSig} /></Field>
      <ActionButton className="btn primary big" disabled={!agree || (minor && (!g.name.trim() || !g.phone.trim()))} onClick={async () => {
        try { await post(`/customers/${customer.id}/waiver-acceptance`, body, { key: idem('waiver', body) }); onAccepted(); } catch (e) { onError(e); }
      }}>Accept & continue</ActionButton>
    </div>
  );
}

// ======================================================================= session
function ChooseSession({ customer, visitId, idem, onCreated, onError, currency }: any) {
  const { config, can } = useApp();
  const [products, setProducts] = useState<any[] | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  const [band, setBand] = useState<string | null>(null);
  const [disc, setDisc] = useState({ on: false, amount: '', reason: '' });
  useEffect(() => { get(`/products?customerId=${customer.id}`).then((r) => setProducts(r.sessions)).catch(onError); }, []); // eslint-disable-line
  if (!products) return <div className="card"><Loading /></div>;
  const chosen = products.find((p) => p.id === sel);
  const discMinor = disc.on ? toMinor(disc.amount) ?? 0 : 0;
  const body = { visitId, pricingRuleId: sel, discountMinor: discMinor || undefined, discountReason: discMinor ? disc.reason : undefined, wristband: band ?? undefined };
  return (
    <div className="card col">
      <h2>Choose session</h2>
      {products.length === 0 ? <Empty>No session options are available for this customer today.</Empty> : <div className="tiles">{products.map((p) => <button key={p.id} className={`tile ${p.id === sel ? 'on' : ''}`} onClick={() => setSel(p.id)}><span className="big">{p.durationMinutes} min</span><span className="lbl">{p.name}</span><span>{formatMoney(p.priceMinor, currency)}</span></button>)}</div>}
      {config!.settings.wristbands.enabled && <Field label="Wristband colour (optional)"><div className="chips">{config!.settings.wristbands.colors.map((c) => <button key={c} className={`chip ${band === c ? 'on' : ''}`} onClick={() => setBand(band === c ? null : c)}>{c}</button>)}</div></Field>}
      {can('payment.discount') && <div className="col gap-s"><label className="check"><input type="checkbox" checked={disc.on} onChange={(e) => setDisc({ ...disc, on: e.target.checked })} /><span>Apply discount / complimentary</span></label>
        {disc.on && <div className="row wrap"><Field label={`Discount (${currency})`}><input className="input" inputMode="decimal" value={disc.amount} onChange={(e) => setDisc({ ...disc, amount: e.target.value })} /></Field><div className="grow"><Field label="Reason"><input className="input" value={disc.reason} onChange={(e) => setDisc({ ...disc, reason: e.target.value })} /></Field></div></div>}</div>}
      <ActionButton className="btn primary big" disabled={!sel || (disc.on && (!discMinor || disc.reason.trim().length < 3 || (chosen && discMinor > chosen.priceMinor)))} onClick={async () => {
        try { onCreated(await post('/sessions', body, { key: idem('session', body) })); } catch (e) { onError(e); }
      }}>Continue{chosen ? ` — ${formatMoney(Math.max(0, chosen.priceMinor - discMinor), currency)}` : ''}</ActionButton>
    </div>
  );
}

// ======================================================================= payment
function Payment({ session, idem, onPaid, onError, currency }: any) {
  const { config } = useApp();
  const methods = config!.settings.paymentMethods;
  const [due, setDue] = useState<number | null>(null);
  const [method, setMethod] = useState(methods[0]?.code);
  const [ref, setRef] = useState('');
  const [unconfirmed, setUnconfirmed] = useState(false);
  const [tender, setTender] = useState('');
  const m = methods.find((x: any) => x.code === method);
  const load = useCallback(async () => { const d = await get(`/sessions/${session.id}`); setDue(d.session.dueMinor - d.session.paidMinor - d.session.pendingMinor); return d.session; }, [session.id]);
  useEffect(() => { load().catch(onError); }, [load]); // eslint-disable-line
  if (due === null) return <div className="card"><Loading /></div>;
  const tendered = toMinor(tender);
  const body = { sessionId: session.id, amountMinor: due, method, reference: ref.trim() || undefined, confirmed: unconfirmed ? false : undefined };
  return (
    <div className="card col">
      <div className="row between"><h2>Payment</h2><div className="kpi" style={{ padding: '6px 12px' }}><div className="label">Amount due</div><div className="value">{formatMoney(due, currency)}</div></div></div>
      {due <= 0 ? <div className="banner info">A payment is already awaiting confirmation for the full amount.</div> : <>
        <Field label="Payment method"><div className="chips">{methods.map((x: any) => <button key={x.code} className={`chip ${x.code === method ? 'on' : ''}`} style={{ minHeight: 48, fontSize: 15 }} onClick={() => setMethod(x.code)}>{x.label}</button>)}</div></Field>
        {m?.requiresReference && <Field label={`${m.label} reference / receipt number`}><input className="input" value={ref} onChange={(e) => setRef(e.target.value)} autoFocus /></Field>}
        {method === 'CASH' && <Field label="Cash received (optional — shows change)"><input className="input" inputMode="decimal" value={tender} onChange={(e) => setTender(e.target.value)} />{tendered !== null && tendered >= due && <span className="hint">Change to give: <b>{formatMoney(tendered - due, currency)}</b></span>}</Field>}
        {m?.requiresReference && <label className="check"><input type="checkbox" checked={unconfirmed} onChange={(e) => setUnconfirmed(e.target.checked)} /><span>Not yet confirmed (awaiting transfer). The session will stay on “awaiting payment”.</span></label>}
        <ActionButton className="btn primary big" disabled={!method || (m?.requiresReference && !unconfirmed && !ref.trim())} onClick={async () => {
          try { await post('/payments', body, { key: idem('payment', body) }); const st = await get(`/sessions/${session.id}`); onPaid(st.session); } catch (e) { onError(e); }
        }}>{unconfirmed ? 'Record pending payment' : `Record ${formatMoney(due, currency)} received`}</ActionButton></>}
    </div>
  );
}

// ======================================================================= start
function StartStep({ session, customer, onStarted, onError }: any) {
  const { config, can, toast } = useApp();
  const [s, setS] = useState<any>(session);
  const [skates, setSkates] = useState<any[]>([]);
  const [picked, setPicked] = useState<string[]>([]);
  const [size, setSize] = useState('');
  const [full, setFull] = useState<{ occupancy: number; max: number; canOverride: boolean } | null>(null);
  const [blocker, setBlocker] = useState<string | null>(null);
  const idem = useIdem();
  useEffect(() => {
    get(`/sessions/${session.id}`).then((d) => setS(d.session)).catch(onError);
    if (can('equipment.assign')) get('/equipment?status=AVAILABLE').then((r) => setSkates(r.items)).catch(() => {});
  }, [session.id]); // eslint-disable-line
  const sizes = useMemo(() => [...new Set(skates.map((k) => k.size).filter(Boolean))].sort((a: any, b: any) => Number(a) - Number(b)), [skates]);
  const shown = skates.filter((k) => !size || k.size === size);
  const body = { equipmentIds: picked.length ? picked : undefined, wristband: s.wristband ?? undefined };
  const key = idem('start', body);
  async function start(override?: string) {
    setBlocker(null);
    try { await post(`/sessions/${session.id}/start`, { ...body, overrideCapacityReason: override }, { key: override ? newKey() : key }); onStarted(); }
    catch (e) {
      if (e instanceof ApiError && e.code === 'VENUE_FULL') setFull({ occupancy: e.details?.occupancy, max: e.details?.max, canOverride: !!e.details?.canOverride });
      else if (e instanceof ApiError && ['WAIVER_REQUIRED', 'PAYMENT_INCOMPLETE', 'GUARDIAN_WAIVER_REQUIRED'].includes(e.code)) { setBlocker(e.message); toast('error', e.message); }
      else onError(e);
    }
  }
  const needEquip = config!.settings.equipmentRequiredForStart && picked.length === 0;
  return (
    <div className="card col">
      <h2>Ready to start</h2>
      <div className="row"><Photo id={customer.photoId} name={customer.fullName} size="lg" /><div className="col gap-s"><b style={{ fontSize: 20 }}>{customer.fullName}</b><span className="muted">{s.productName} · {Math.round(s.currentDurationSeconds / 60)} minutes</span><span className="badge lvl-normal"><Icon n="check" />Paid {formatMoney(s.paidMinor, s.currency)}</span></div></div>
      {can('equipment.assign') && skates.length > 0 && <div className="col gap-s"><h3>Issue rental skates (optional)</h3>
        {sizes.length > 1 && <div className="chips"><button className={`chip ${!size ? 'on' : ''}`} onClick={() => setSize('')}>All sizes</button>{sizes.map((z: any) => <button key={z} className={`chip ${size === z ? 'on' : ''}`} onClick={() => setSize(z)}>Size {z}</button>)}</div>}
        <div className="chips">{shown.slice(0, 60).map((k) => <button key={k.id} className={`chip ${picked.includes(k.id) ? 'on' : ''}`} style={{ minHeight: 44 }} onClick={() => setPicked(picked.includes(k.id) ? picked.filter((x) => x !== k.id) : [...picked, k.id])}>{k.code.replace('SKATE-', '#')}{k.size ? ` · ${k.size}` : ''}</button>)}</div>
        {picked.length > 0 && <span className="hint">Selected: {skates.filter((k) => picked.includes(k.id)).map((k) => k.code).join(', ')}</span>}</div>}
      {blocker && <ErrorBox error={{ message: blocker }} />}
      {full && <div className="banner red" role="alert"><Icon n="lock" size={22} /><div><b>VENUE FULL</b> — {full.occupancy} / {full.max} inside. The server will not start another session.
        {full.canOverride && <div style={{ marginTop: 8 }}><button className="btn" onClick={() => { const r = prompt('Manager override — reason for exceeding capacity:'); if (r?.trim()) start(r.trim()); }}>Override capacity…</button></div>}</div></div>}
      <ActionButton className="btn good big" disabled={needEquip || !!full} onClick={() => start()}><Icon n="play" size={22} /> START SKATING</ActionButton>
      {needEquip && <span className="hint">This venue requires skates to be issued before starting.</span>}
    </div>
  );
}
