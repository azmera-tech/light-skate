import { describe, it, expect, beforeAll } from 'vitest';
import { pool } from '../src/db.js';
import { makeWorld, activeSession, readySession, addSkates, makePng, drainOutbox, type World } from './helpers.js';

let w: World;
beforeAll(async () => { w = await makeWorld({ capacity: 100 }); });
const status = async (id: string) => (await pool.query('SELECT status FROM equipment WHERE id=$1', [id])).rows[0].status;
const events = async (id: string) => (await pool.query('SELECT event_type FROM equipment_events WHERE equipment_id=$1 ORDER BY id', [id])).rows.map((r) => r.event_type);

describe('equipment lifecycle', () => {
  it('issue -> return keeps a full immutable history', async () => {
    const [s] = await addSkates(w, 1, 'LIFE');
    const a = await activeSession(w);
    const iss = await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: a.sessionId });
    expect(iss.status).toBe(200);
    expect(await status(s)).toBe('ISSUED');
    const dupAssign = await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: a.sessionId });
    expect(dupAssign.status).toBe(409);
    expect(dupAssign.body.error.message).toBe('LIFE-001 is no longer available.');
    const live = await w.api('front', 'GET', '/equipment');
    expect(live.body.items.find((e: any) => e.id === s).issuedTo).toBe('Abebe Kebede');
    expect(live.body.summary.ISSUED).toBe(1);
    // ending the session does not silently return equipment; visit stays open
    const end = await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    expect(end.body.equipmentOutstanding).toEqual(['LIFE-001']);
    expect(end.body.visitCompleted).toBe(false);
    const ret = await w.api('rental', 'POST', `/equipment/${s}/return`, { condition: 'GOOD' });
    expect(ret.status).toBe(200);
    expect(ret.body.visitCompleted).toBe(true);
    expect(await status(s)).toBe('AVAILABLE');
    expect(await events(s)).toEqual(['CREATED', 'ISSUED', 'RETURNED', 'RETURNED_TO_STOCK']);
    const again = await w.api('rental', 'POST', `/equipment/${s}/return`, { condition: 'GOOD' });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('EQUIPMENT_NOT_ISSUED');
    const a2 = (await pool.query('SELECT assigned_by, returned_by, returned_at FROM equipment_assignments WHERE equipment_id=$1', [s])).rows[0];
    expect(a2.assigned_by).toBe(w.userIds.rental_staff);
    expect(a2.returned_at).not.toBeNull();
    await expect(pool.query('DELETE FROM equipment_events WHERE equipment_id=$1', [s])).rejects.toThrow(/append-only/);
  });

  it('cannot issue to a session that is not checked in, or to a finished one', async () => {
    const [s] = await addSkates(w, 1, 'ELIG');
    const ready = await readySession(w);
    const notYet = await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: ready.sessionId });
    expect(notYet.status).toBe(409);
    expect(notYet.body.error.code).toBe('SESSION_NOT_ELIGIBLE');
    const done = await activeSession(w);
    await w.api('front', 'POST', `/sessions/${done.sessionId}/end`, {});
    expect((await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: done.sessionId })).status).toBe(409);
  });

  it('start can issue equipment atomically with the session', async () => {
    const [a, b] = await addSkates(w, 2, 'WITH');
    const r = await readySession(w);
    const st = await w.api('front', 'POST', `/sessions/${r.sessionId}/start`, { equipmentIds: [a, b] });
    expect(st.status).toBe(200);
    expect(st.body.equipment.map((e: any) => e.code).sort()).toEqual(['WITH-001', 'WITH-002']);
    expect(await status(a)).toBe('ISSUED');
    expect(await status(b)).toBe('ISSUED');
  });

  it('damage on return: unit goes to DAMAGED with an open maintenance record and cannot be issued', async () => {
    const [s] = await addSkates(w, 1, 'DMG');
    const a = await activeSession(w, { equipmentIds: [s] });
    await w.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    const ret = await w.api('rental', 'POST', `/equipment/${s}/return`, { condition: 'DAMAGED', note: 'Broken wheel' });
    expect(ret.body.status).toBe('DAMAGED');
    const rec = (await pool.query('SELECT issue, status FROM maintenance_records WHERE equipment_id=$1', [s])).rows[0];
    expect(rec).toEqual({ issue: 'Broken wheel', status: 'OPEN' });
    const b = await activeSession(w);
    const tryIssue = await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: b.sessionId });
    expect(tryIssue.status).toBe(409);
    expect(tryIssue.body.error.message).toMatch(/DMG-001 is not available \(damaged\)/);
    // photo of the damage, private
    const ph = await w.api('rental', 'POST', `/equipment/${s}/maintenance/photo`, makePng(200, 200));
    expect(ph.status).toBe(201);
    expect((await w.api('rental', 'GET', `/equipment/${s}/maintenance/photo`)).status).toBe(200);
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/equipment/${s}/maintenance/photo` })).statusCode).toBe(401);
    // repair and return to service
    expect((await w.api('rental', 'POST', `/equipment/${s}/maintenance/start`)).status).toBe(200);
    expect(await status(s)).toBe('MAINTENANCE');
    expect((await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: b.sessionId })).status).toBe(409);
    const done = await w.api('rental', 'POST', `/equipment/${s}/maintenance/complete`, { resolution: 'Replaced wheel' });
    expect(done.body.status).toBe('AVAILABLE');
    expect((await w.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: b.sessionId })).status).toBe(200);
    const hist = await events(s);
    expect(hist).toEqual(expect.arrayContaining(['ISSUED', 'RETURNED', 'DAMAGED', 'MAINTENANCE_STARTED', 'MAINTENANCE_COMPLETED', 'RETURNED_TO_SERVICE']));
    const detail = await w.api('rental', 'GET', `/equipment/${s}`);
    expect(detail.body.usage.timesIssued).toBe(2);
    expect(detail.body.usage.timesRepaired).toBe(1);
  });

  it('standalone damage report makes the unit unavailable immediately; out-of-service is enforced', async () => {
    const [s, t] = await addSkates(w, 2, 'REP');
    const d = await w.api('rental', 'POST', `/equipment/${s}/damage`, { issue: 'Cracked boot' });
    expect(d.body.status).toBe('MAINTENANCE');
    await w.api('rental', 'POST', `/equipment/${s}/maintenance/complete`, {});
    const held = await activeSession(w, { equipmentIds: [s] });
    const cannot = await w.api('rental', 'POST', `/equipment/${s}/damage`, { issue: 'while customer has it' });
    expect(cannot.status).toBe(409);
    expect(cannot.body.error.code).toBe('EQUIPMENT_ISSUED');
    expect((await w.api('rental', 'POST', `/equipment/${t}/out-of-service`, { reason: 'Unsafe frame' })).status).toBe(200);
    expect((await w.api('rental', 'POST', `/equipment/${t}/assign`, { sessionId: held.sessionId })).status).toBe(409);
    expect((await w.api('front', 'POST', `/equipment/${t}/out-of-service`, { reason: 'x y z' })).status).toBe(403);
    await drainOutbox();
    const n = await w.api('manager', 'GET', '/notifications?status=OPEN');
    expect(n.body.notifications.some((x: any) => x.type === 'EQUIPMENT_DAMAGED')).toBe(true);
  });

  it('inspect-on-return setting routes returned units through RETURNED until inspected', async () => {
    const w2 = await makeWorld();
    await w2.api('owner', 'PUT', '/settings', { inspectOnReturn: true });
    const [s] = await addSkates(w2, 1, 'INSP');
    const a = await activeSession(w2, { equipmentIds: [s] });
    await w2.api('front', 'POST', `/sessions/${a.sessionId}/end`, {});
    await w2.api('rental', 'POST', `/equipment/${s}/return`, { condition: 'GOOD' });
    expect(await status(s)).toBe('RETURNED');
    const b = await activeSession(w2);
    expect((await w2.api('rental', 'POST', `/equipment/${s}/assign`, { sessionId: b.sessionId })).status).toBe(409);
    expect((await w2.api('rental', 'POST', `/equipment/${s}/inspect`)).status).toBe(200);
    expect(await status(s)).toBe('AVAILABLE');
  });

  it('duplicate equipment codes are refused with a clear message', async () => {
    await w.api('owner', 'POST', '/equipment', { code: 'DUP-1' });
    const r = await w.api('owner', 'POST', '/equipment', { code: 'dup-1' });
    expect(r.status).toBe(409);
    expect(r.body.error.code).toBe('EQUIPMENT_CODE_EXISTS');
  });
});

describe('incidents', () => {
  it('follows the lifecycle with an event per step; illegal jumps are refused; critical closure needs a note', async () => {
    const a = await activeSession(w);
    const inc = await w.api('front', 'POST', '/incidents', { sessionId: a.sessionId, incidentType: 'Collision', severity: 'CRITICAL', description: 'Two skaters collided, ambulance called', actionTaken: 'First aid, ambulance', managerNotified: true });
    expect(inc.status).toBe(201);
    expect(inc.body.incidentNumber).toMatch(/^INC-\d{8}-\d{3}$/);
    expect(inc.body.customerId).toBe(a.customerId);
    expect(inc.body.visitId).toBe(a.visitId);
    const id = inc.body.id;
    expect((await w.api('front', 'POST', `/incidents/${id}/transition`, { to: 'ACKNOWLEDGED' })).status).toBe(403);
    const closeEarly = await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'CLOSED' });
    expect(closeEarly.status).toBe(409);
    expect((await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'ACKNOWLEDGED' })).status).toBe(200);
    expect((await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'ACTION_TAKEN', actionTaken: 'Taken to hospital' })).status).toBe(200);
    const noNote = await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'CLOSED' });
    expect(noNote.status).toBe(422);
    expect((await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'CLOSED', note: 'Family informed, report filed' })).status).toBe(200);
    expect((await w.api('manager', 'POST', `/incidents/${id}/transition`, { to: 'ACKNOWLEDGED' })).status).toBe(409);
    const detail = await w.api('manager', 'GET', `/incidents/${id}`);
    expect(detail.body.events.map((e: any) => e.eventType)).toEqual(['INCIDENT_REPORTED', 'INCIDENT_ACKNOWLEDGED', 'INCIDENT_ACTION_TAKEN', 'INCIDENT_CLOSED']);
    await drainOutbox();
    const notes = await w.api('manager', 'GET', '/notifications');
    expect(notes.body.notifications.some((n: any) => n.type === 'INCIDENT_REPORTED' && n.severity === 'CRITICAL')).toBe(true);
    const dash = await w.api('manager', 'GET', '/dashboard');
    expect(typeof dash.body.openIncidents).toBe('number');
    expect((await w.api('front', 'GET', '/dashboard')).body.openIncidents).toBeNull();
  });

  it('attachments are validated, private and only the reporter or a manager can add them', async () => {
    const inc = await w.api('front', 'POST', '/incidents', { incidentType: 'Equipment', severity: 'MINOR', description: 'Loose wheel seen on rink' });
    const up = await w.api('front', 'POST', `/incidents/${inc.body.id}/attachments`, makePng(200, 200));
    expect(up.status).toBe(201);
    expect((await w.api('front', 'POST', `/incidents/${inc.body.id}/attachments`, Buffer.from('not an image at all, sorry'))).status).toBe(400);
    expect((await w.api('rental', 'POST', `/incidents/${inc.body.id}/attachments`, makePng(200, 200))).status).toBe(403);
    expect((await w.api('front', 'GET', `/incident-attachments/${up.body.id}/content`)).status).toBe(403); // reporter can add but not read back details
    expect((await w.api('manager', 'GET', `/incident-attachments/${up.body.id}/content`)).status).toBe(200);
    expect((await w.app.inject({ method: 'GET', url: `/api/v1/incident-attachments/${up.body.id}/content` })).statusCode).toBe(401);
  });
});
