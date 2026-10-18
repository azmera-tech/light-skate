-- 009: lock every table down from Supabase's public PostgREST API (anon/authenticated).
-- No policies are added, which is deliberate: this backend never uses the anon/authenticated
-- roles. It connects with its own direct Postgres role, which (as table owner / a role with
-- BYPASSRLS, matching Supabase's "postgres"/service connection) is unaffected by RLS. This is
-- purely a lockout of the public REST surface Supabase auto-generates over this schema.
ALTER TABLE "public"."venues" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."staff_profiles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."devices" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."auth_sessions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."emergency_contacts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."customer_photos" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."waivers" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."waiver_versions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."waiver_acceptances" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pricing_rules" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."capacity_rules" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."counters" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."visits" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sessions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."session_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."session_extensions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."session_pauses" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payment_transactions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payment_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."refunds" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."equipment" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."equipment_assignments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."equipment_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."maintenance_records" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."incidents" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."incident_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."incident_attachments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notification_deliveries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."outbox_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."idempotency_keys" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."day_closes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."shoe_claims" ENABLE ROW LEVEL SECURITY;
