-- ========================================================================
-- Streamlined Social Media Management (SMM) Schema
-- ========================================================================

-- 1. Social Posts Table (Unified Ideas & Platform Variants)
CREATE TABLE IF NOT EXISTS social_posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  key_message TEXT NOT NULL,
  media_urls JSONB DEFAULT '[]'::jsonb,
  target_platforms JSONB NOT NULL DEFAULT '["linkedin", "twitter", "instagram"]'::jsonb,
  variants JSONB DEFAULT '{}'::jsonb, -- { "linkedin": "...", "twitter": "...", "instagram": "..." }
  status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'ready_for_approval', 'approved', 'scheduled', 'published', 'failed')),
  scheduled_for TIMESTAMPTZ,
  scheduler_post_id TEXT, -- ID returned by Ayrshare API
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Social Conversations & Handoff State (ManyChat / Instagram / WhatsApp)
CREATE TABLE IF NOT EXISTS social_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscriber_id TEXT UNIQUE NOT NULL, -- ManyChat subscriber ID
  platform TEXT NOT NULL CHECK (platform IN ('instagram', 'facebook', 'whatsapp', 'telegram')),
  is_human_takeover BOOLEAN DEFAULT false,
  paused_until TIMESTAMPTZ,
  bot_reply_count INTEGER DEFAULT 0,
  last_interaction_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 3. Social Messages (Telemetry & Audit)
CREATE TABLE IF NOT EXISTS social_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID REFERENCES social_conversations(id) ON DELETE CASCADE,
  external_message_id TEXT UNIQUE NOT NULL,
  sender_type TEXT NOT NULL CHECK (sender_type IN ('subscriber', 'bot', 'agent')),
  intent TEXT,
  content TEXT NOT NULL,
  status TEXT DEFAULT 'delivered' CHECK (status IN ('delivered', 'escalated', 'quarantined', 'failed')),
  token_usage JSONB DEFAULT '{}'::jsonb,
  latency_ms INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Performance & Query Indexes
CREATE INDEX IF NOT EXISTS idx_social_posts_status ON social_posts(status);
CREATE INDEX IF NOT EXISTS idx_social_posts_scheduled_for ON social_posts(scheduled_for);
CREATE INDEX IF NOT EXISTS idx_social_conv_subscriber ON social_conversations(subscriber_id);
CREATE INDEX IF NOT EXISTS idx_social_msg_conv ON social_messages(conversation_id);
