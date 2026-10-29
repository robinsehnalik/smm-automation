-- ========================================================================
-- Hardened Social Media Management (SMM) Schema
-- ========================================================================

-- 1. Revoke default privileges from public, anon, and authenticated roles
REVOKE ALL ON SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO service_role;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL ROUTINES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON ROUTINES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;

-- 2. Conversation State Table (Muting, Window Tracking & Rate Counter)
-- Note: No message content is stored.
CREATE TABLE IF NOT EXISTS conversation_state (
  subscriber_id TEXT PRIMARY KEY,
  platform TEXT NOT NULL CHECK (platform IN ('instagram', 'facebook')),
  paused_until TIMESTAMPTZ,
  window_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  reply_count INTEGER NOT NULL DEFAULT 0,
  last_interaction_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_conversation_state_paused ON conversation_state(paused_until);
CREATE INDEX IF NOT EXISTS idx_conversation_state_last_interaction ON conversation_state(last_interaction_at);

-- 3. Bot Events Table (Idempotency Claim, Intent Telemetry & Audit Log)
-- Note: No message bodies are stored. Only hashed subscriber IDs and classified metadata.
CREATE TABLE IF NOT EXISTS bot_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_key TEXT UNIQUE NOT NULL,
  subscriber_hash TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('instagram', 'facebook')),
  intents TEXT[] NOT NULL DEFAULT '{}',
  sensitive BOOLEAN NOT NULL DEFAULT false,
  action TEXT NOT NULL CHECK (action IN (
    'replied',
    'escalated',
    'muted',
    'rate_limited',
    'shadow',
    'disabled',
    'invalid_output',
    'error'
  )),
  template_ids TEXT[] NOT NULL DEFAULT '{}',
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  latency_ms INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bot_events_event_key ON bot_events(event_key);
CREATE INDEX IF NOT EXISTS idx_bot_events_created_at ON bot_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bot_events_action ON bot_events(action);

-- 4. Atomic Rate Counter Function
-- Upsert that resets the window when expired, returning true if allowed
CREATE OR REPLACE FUNCTION bump_reply_counter(
  p_subscriber_id TEXT,
  p_platform TEXT,
  p_window_minutes INTEGER DEFAULT 60,
  p_max_replies INTEGER DEFAULT 5
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allowed BOOLEAN;
BEGIN
  INSERT INTO conversation_state (
    subscriber_id,
    platform,
    window_start,
    reply_count,
    last_interaction_at
  )
  VALUES (
    p_subscriber_id,
    p_platform,
    now(),
    1,
    now()
  )
  ON CONFLICT (subscriber_id) DO UPDATE
  SET
    platform = EXCLUDED.platform,
    last_interaction_at = now(),
    window_start = CASE
      WHEN conversation_state.window_start < now() - (p_window_minutes || ' minutes')::interval THEN now()
      ELSE conversation_state.window_start
    END,
    reply_count = CASE
      WHEN conversation_state.window_start < now() - (p_window_minutes || ' minutes')::interval THEN 1
      ELSE conversation_state.reply_count + 1
    END
  RETURNING (reply_count <= p_max_replies) INTO v_allowed;

  RETURN v_allowed;
END;
$$;

REVOKE EXECUTE ON FUNCTION bump_reply_counter(TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION bump_reply_counter(TEXT, TEXT, INTEGER, INTEGER) TO service_role;

-- 5. Row Level Security: Deny-by-Default on All Tables
-- Service role bypasses RLS; anon and authenticated have zero policies
ALTER TABLE conversation_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_events ENABLE ROW LEVEL SECURITY;

-- 6. Automated Data Retention Purge Routine
CREATE OR REPLACE FUNCTION purge_expired_data()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Telemetry events: 30 days
  DELETE FROM bot_events WHERE created_at < now() - INTERVAL '30 days';
  -- Conversation states idle for more than 30 days
  DELETE FROM conversation_state WHERE last_interaction_at < now() - INTERVAL '30 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION purge_expired_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION purge_expired_data() TO service_role;

-- 7. Optional pg_cron Scheduling (if pg_cron extension is enabled on the instance)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'purge-smm-retention-job',
      '0 3 * * *',
      'SELECT public.purge_expired_data();'
    );
  END IF;
END;
$$;

-- 8. Service Role Full Access Grant
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA public TO service_role;
