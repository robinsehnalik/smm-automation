# Social Media Management (SMM) Automation — Implementation Guide

## 1. System Overview

The **Social Media Management (SMM) System** provides intelligent multi-platform content scheduling and safe inbound community triage.

The system is organized into two distinct, decoupled pipelines:
* **Phase 1: Outbound Publishing (Ayrshare)**: Automatically transforms content topics into tailored, validated copy for LinkedIn, X (Twitter), and Instagram. Upon approval, posts are pushed directly to Ayrshare with `scheduleDate` for automated publishing.
* **Phase 2: Inbound Community Triage (ManyChat)**: Ingests incoming Instagram DMs, Facebook messages, and comments via authenticated webhooks. Evaluates customer intent against a strict **Intent Allowlist**, auto-replying only to safe informational queries while escalating sensitive issues to live agents in ManyChat.

```
PHASE 1: OUTBOUND PUBLISHING FLOW
[Airtable / Content Idea] ──► [SMM-POST-01 Variant Generator] ──► [Strict Code Validation]
                                                                         │
                                                                         ▼
[Ayrshare Native Scheduling] ◄── [SMM-POST-02 Dispatcher] ◄── [One-Click Human Approval]
        │
        ▼
[Published to LinkedIn / X / Instagram]

PHASE 2: INBOUND MESSAGING FLOW
[Customer DM in Instagram] ──► [ManyChat Webhook] ──► [SMM-MSG-01 Community Triage]
                                                              │
                                            ┌─────────────────┴─────────────────┐
                                            ▼                                   ▼
                                   [Safe Intent Allowlist]              [Human Handoff]
                                            │                                   │
                                            ▼                                   ▼
                                    [Auto-Reply Sent]                  [Bot Muted & Live Chat Open]
```

---

## 2. Workflows Included (`n8n-workflows/`)

| File | Name | Trigger | Primary Purpose |
| :--- | :--- | :--- | :--- |
| [`smm-post-01-variant-generator.json`](./n8n-workflows/smm-post-01-variant-generator.json) | SMM-POST-01 Variant Generator | Webhook (`POST /smm/generate-variants`) | Generates tailored copy for LinkedIn, X, and Instagram. Enforces code-level character counts and media presence for Instagram. |
| [`smm-post-02-approval-dispatcher.json`](./n8n-workflows/smm-post-02-approval-dispatcher.json) | SMM-POST-02 Approval Dispatcher | Webhook (`POST /smm/dispatch-approved-post`) | Formats approved copy and pushes directly to Ayrshare API with `scheduleDate`. |
| [`smm-msg-01-triage-pipeline.json`](./n8n-workflows/smm-msg-01-triage-pipeline.json) | SMM-MSG-01 Community Triage Pipeline | ManyChat Webhook (`POST /smm/manychat-webhook`) | Verifies secret, checks bot muting/handoff state, matches safe intent allowlist, and dispatches reply or escalates. |
| [`smm-err-error-handler.json`](./n8n-workflows/smm-err-error-handler.json) | SMM-ERR Global Error Handler | Error Trigger | Global exception handler that logs failures and alerts the administrator via email. |

---

## 3. Database Setup (Supabase)

Execute [`sql/schema.sql`](./sql/schema.sql) in your Supabase SQL Editor:

```sql
-- 1. Social Posts Table (Unified Ideas & Platform Variants)
CREATE TABLE IF NOT EXISTS social_posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  key_message TEXT NOT NULL,
  media_urls JSONB DEFAULT '[]'::jsonb,
  target_platforms JSONB NOT NULL DEFAULT '["linkedin", "twitter", "instagram"]'::jsonb,
  variants JSONB DEFAULT '{}'::jsonb,
  status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'ready_for_approval', 'approved', 'scheduled', 'published', 'failed')),
  scheduled_for TIMESTAMPTZ,
  scheduler_post_id TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Social Conversations & Handoff State
CREATE TABLE IF NOT EXISTS social_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscriber_id TEXT UNIQUE NOT NULL,
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
```

---

## 4. Environment Variables Configuration

| Variable | Description | Used In |
| :--- | :--- | :--- |
| `OPENAI_API_KEY` | OpenAI API key (`gpt-4o`) for variant generation & message triage | `SMM-POST-01`, `SMM-MSG-01` |
| `AYRSHARE_API_KEY` | API key from your Ayrshare account (`app.ayrshare.com`) | `SMM-POST-02` |
| `MANYCHAT_API_KEY` | API token from your ManyChat Pro account (`Settings > API`) | `SMM-MSG-01` |
| `SMM_WEBHOOK_SECRET` | Secret token to authenticate incoming webhooks (`X-Webhook-Secret`) | `SMM-MSG-01` |
| `LINK_TO_YOUR_SUPABASE_URL` | Supabase API endpoint (e.g. `https://xyz.supabase.co`) | All Workflows |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service role key | All Workflows |
| `RESEND_API_KEY` | Resend API key for administrative error alerts | `SMM-ERR` |
| `SYSTEM_SENDER_EMAIL` | Verified sending address for alerts | `SMM-ERR` |
| `ADMIN_NOTIFICATION_EMAIL` | Destination mailbox for error alerts | `SMM-ERR` |
