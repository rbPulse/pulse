-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — guard_integrations_protected_columns: skip service role
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Migration 023's guard trigger blocks non-platform users from
--   writing `credentials` + system-managed columns on
--   tenant_integrations. That was the right call for direct DB
--   writes from tenant-admin sessions, but it unintentionally also
--   blocked Unite's own edge functions (resend-domain-verify,
--   twilio-save-creds, twilio-ping) which use SUPABASE_SERVICE_ROLE_KEY
--   to update credentials + last_connected_at / last_error.
--
--   Under the service role, auth.uid() is NULL → is_platform_user()
--   returns false → guard raises 'credentials are platform-owned'.
--   Edge functions that didn't explicitly check the update return
--   silently reported success while nothing changed.
--
--   This migration teaches the guard to recognise service-role calls
--   and bypass the column protections. Service role IS the trusted
--   server surface these protections are defending against tenant
--   misuse; there's no layering win from double-gating it.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_integrations_protected_columns()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Bypass 1: Unite edge functions running under the service role.
  -- Supabase exposes the role via auth.role(); belt-and-suspenders
  -- with current_user handles local / alternate connection setups.
  IF auth.role() = 'service_role'
     OR current_user = 'service_role'
     OR current_user = 'postgres' THEN
    RETURN NEW;
  END IF;

  -- Bypass 2: Unite platform operators.
  IF public.is_platform_user() THEN
    RETURN NEW;
  END IF;

  IF NEW.credentials       IS DISTINCT FROM OLD.credentials       THEN RAISE EXCEPTION 'credentials are platform-owned'; END IF;
  IF NEW.tenant_id         IS DISTINCT FROM OLD.tenant_id         THEN RAISE EXCEPTION 'tenant_id is immutable'; END IF;
  IF NEW.provider          IS DISTINCT FROM OLD.provider          THEN RAISE EXCEPTION 'provider is immutable'; END IF;
  IF NEW.id                IS DISTINCT FROM OLD.id                THEN RAISE EXCEPTION 'id is immutable'; END IF;
  IF NEW.created_at        IS DISTINCT FROM OLD.created_at        THEN RAISE EXCEPTION 'created_at is immutable'; END IF;
  IF NEW.last_connected_at IS DISTINCT FROM OLD.last_connected_at THEN RAISE EXCEPTION 'last_connected_at is system-managed'; END IF;
  IF NEW.last_error        IS DISTINCT FROM OLD.last_error        THEN RAISE EXCEPTION 'last_error is system-managed'; END IF;
  IF NEW.last_error_at     IS DISTINCT FROM OLD.last_error_at     THEN RAISE EXCEPTION 'last_error_at is system-managed'; END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status NOT IN ('connected', 'disconnected') THEN
      RAISE EXCEPTION 'status can only be set to connected or disconnected by tenant admins';
    END IF;
  END IF;

  IF NEW.mode IS DISTINCT FROM OLD.mode THEN
    IF NEW.mode NOT IN ('test','live') THEN
      RAISE EXCEPTION 'mode must be test or live';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

SELECT 'guard_integrations_protected_columns updated — service role now bypasses' AS status;
