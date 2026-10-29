# Social Media Management (SMM) Automation — Implementation Guide & Overview

## 1. System Overview
The **Social Media Management (SMM) Automation** system operates two synchronized pipelines powered by **3rd-party social schedulers** (Ayrshare, Buffer, Publer) and **3rd-party messaging platforms** (ManyChat, Gorgias, Zendesk):

1. **Outbound Content Pipeline**: Ingests content ideas, uses OpenAI (`gpt-4o`) to generate platform-native copy (LinkedIn, X, Instagram, Facebook), supports one-click dashboard approvals, and schedules/publishes posts via the 3rd-party scheduler API.
2. **Inbound Community Management Pipeline**: Ingests DMs and comments via 3rd-party messaging webhooks, checks deduplication, analyzes sentiment & brand risk with LLM RAG, automatically responds to high-confidence inquiries via the messaging API, and escalates complaints or sensitive topics to human agents.

```
PIPELINE A: Outbound Content Publishing
[Idea / Calendar Trigger] ──► [SMM-P1 Content Intake]
                                       │
                                       ▼
                       [SMM-P2 LLM Platform Variants]
                       (LinkedIn, X, Instagram, Facebook)
                                       │
                                       ▼
                         [Review in Dashboard Queue]
                                       │
                                       ▼
                       [SMM-P3 Scheduler & Publisher]
                                       │
                                       ▼
                   [3rd-Party Scheduler API (Ayrshare / Buffer)]
                                       │
                                       ▼
                     [Social Networks (LI, X, IG, FB)]

PIPELINE B: Inbound Community Management
[Inbound Comment / DM] ──► [3rd-Party Messenger (ManyChat / Helpdesk)]
                                                │
                                                ▼
                                  [SMM-M1 Event Trigger Intake]
                                                │
                                                ▼
                                   [SMM-M2 LLM Response Builder]
                                                │
                               ┌────────────────┴────────────────┐
                               ▼                                 ▼
                     [Confidence >= 0.85]              [Sensitive / Low Conf]
                               │                                 │
                               ▼                                 ▼
                   [SMM-M3 Messenger Dispatch]      [SMM-M4 Human Escalation]
                               │                                 │
                               ▼                                 ▼
                   [3rd-Party Messenger API]         [Email Alert + Handoff Tag]
```

---

## 2. Workflows Included (`n8n-workflows/`)

| File | Name | Trigger | Primary Purpose |
| :--- | :--- | :--- | :--- |
| [`smm-p1-content-intake.json`](./n8n-workflows/smm-p1-content-intake.json) | SMM-P1 Content Intake | Webhook (`POST /smm/idea-intake`) | Captures raw post idea, target platforms, and media URLs. |
| [`smm-p2-llm-platform-variants.json`](./n8n-workflows/smm-p2-llm-platform-variants.json) | SMM-P2 LLM Platform Variants | Webhook (`POST /smm/variants`) | Generates platform-tailored copy, hashtags, and formatting. |
| [`smm-p3-scheduler-publisher.json`](./n8n-workflows/smm-p3-scheduler-publisher.json) | SMM-P3 Scheduler & Publisher | Cron (`* * * * *` Every min) | Dispatches due posts to 3rd-party scheduler API (Ayrshare / Buffer). |
| [`smm-p4-notifications-metrics.json`](./n8n-workflows/smm-p4-notifications-metrics.json) | SMM-P4 Notifications & Metrics | Cron (`0 18 * * *` Daily) | Syncs engagement analytics from scheduler API to Supabase. |
| [`smm-m1-event-trigger-intake.json`](./n8n-workflows/smm-m1-event-trigger-intake.json) | SMM-M1 Event Trigger Intake | Webhook (`POST /smm/events`) | Ingests webhooks from ManyChat / Gorgias, normalizes and dedupes. |
| [`smm-m2-llm-response-builder.json`](./n8n-workflows/smm-m2-llm-response-builder.json) | SMM-M2 LLM Response Builder | Webhook (`POST /smm/response-builder`) | Evaluates risk, generates grounded reply draft, routes to auto-reply vs human. |
| [`smm-m3-messenger-dispatch.json`](./n8n-workflows/smm-m3-messenger-dispatch.json) | SMM-M3 Messenger Dispatch | Webhook (`POST /smm/dispatch`) | Dispatches approved reply via 3rd-party messaging platform API. |
| [`smm-m4-notifications-escalation.json`](./n8n-workflows/smm-m4-notifications-escalation.json) | SMM-M4 Notifications & Escalation | Webhook (`POST /smm/escalate`) | Tags subscriber in messenger and alerts owner via email for human review. |
| [`smm-err-error-handler.json`](./n8n-workflows/smm-err-error-handler.json) | SMM-ERR Error Handler | Error Trigger | Captures workflow failures and alerts system administrator. |

---

## 3. Database Schema (Supabase)

Execute the following SQL in your Supabase SQL Editor:

```sql
-- 1. Content Ideas & Posts
CREATE TABLE IF NOT EXISTS content_ideas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic TEXT NOT NULL,
  key_message TEXT NOT NULL,
  target_platforms TEXT[] DEFAULT '{linkedin,x}',
  target_date TIMESTAMPTZ,
  media_refs TEXT[] DEFAULT '{}',
  status TEXT DEFAULT 'idea',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idea_id UUID REFERENCES content_ideas(id) ON DELETE CASCADE,
  approval_policy TEXT DEFAULT 'approve',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Platform variants
CREATE TABLE IF NOT EXISTS post_variants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('linkedin', 'x', 'instagram', 'facebook')),
  body TEXT NOT NULL,
  publish_at TIMESTAMPTZ,
  status TEXT DEFAULT 'pending_approval' CHECK (status IN ('pending_approval', 'scheduled', 'publishing', 'published', 'failed')),
  platform_post_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 3. Metrics snapshot
CREATE TABLE IF NOT EXISTS post_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  variant_id TEXT NOT NULL,
  impressions INT DEFAULT 0,
  likes INT DEFAULT 0,
  comments INT DEFAULT 0,
  shares INT DEFAULT 0,
  snapshot_date DATE DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. Inbound social messages
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_event_id TEXT UNIQUE,
  direction TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound')),
  event_type TEXT DEFAULT 'dm',
  body TEXT NOT NULL,
  auto_sent BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 5. Central workflow error log
CREATE TABLE IF NOT EXISTS workflow_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_name TEXT NOT NULL,
  node_name TEXT,
  error_message TEXT,
  execution_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

---

## 4. Environment Variables Configuration

Configure these variables in your n8n `.env` or credentials vault:

| Variable | Description | Example Value |
| :--- | :--- | :--- |
| `LINK_TO_YOUR_N8N_INSTANCE` | Host URL of n8n | `https://n8n.yourcompany.com` |
| `LINK_TO_YOUR_SUPABASE_URL` | Supabase API endpoint | `https://xyzproject.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase Service Role key | `eyJhbGciOiJIUzI1NiIsIn...` |
| `OPENAI_API_KEY` | OpenAI API key for `gpt-4o` | `sk-proj-...` |
| `LINK_TO_YOUR_SCHEDULER_API` | 3rd-party scheduler API endpoint (Ayrshare/Buffer) | `https://app.ayrshare.com/api/post` |
| `SCHEDULER_API_KEY` | API token for your social scheduler | `ayr_live_...` |
| `LINK_TO_YOUR_MESSENGER_API` | 3rd-party messaging API endpoint (ManyChat/Gorgias) | `https://api.manychat.com/fb/sending/sendContent` |
| `MESSENGER_API_KEY` | API token for your messaging platform | `manychat_bearer_...` |
| `RESEND_API_KEY` | Resend API key for alerts | `re_...` |
| `SYSTEM_SENDER_EMAIL` | Sender address | `social-alerts@yourcompany.com` |
| `OWNER_NOTIFICATION_EMAIL` | Owner address for approvals/escalations | `owner@yourcompany.com` |
| `ADMIN_NOTIFICATION_EMAIL` | Admin address for error alerts | `admin@yourcompany.com` |
| `LINK_TO_YOUR_DASHBOARD` | Dashboard frontend URL | `https://dashboard.yourcompany.com` |

---

## 5. Deployment & Testing Steps

1. **Import & Activate Workflows**:
   - In n8n, navigate to **Workflows > Import from File**.
   - Import all 9 JSON files from [`n8n-workflows/`](./n8n-workflows/).
   - Activate `SMM-ERR`, `SMM-P4`, `SMM-P3`, down to `SMM-P1`.
2. **Submit Content Idea (Posting Pipeline)**:
   ```bash
   curl -X POST "https://n8n.yourcompany.com/webhook/smm/idea-intake" \
     -H "Content-Type: application/json" \
     -d '{
       "topic": "Scaling Customer Operations with AI Agents",
       "key_message": "How modern companies resolve 70% of inbound DMs automatically while escalating sensitive issues to humans.",
       "target_platforms": ["linkedin", "x"]
     }'
   ```
3. **Approve and Dispatch to Scheduler**:
   - In Supabase `post_variants`, mark the approved variant with `status = 'scheduled'` and set `publish_at = now()`.
   - Within 60 seconds, `SMM-P3` dispatches the post to your 3rd-party scheduler API (Ayrshare/Buffer) and sets `status = 'published'`.
4. **Test Inbound Message (Messaging Pipeline)**:
   ```bash
   curl -X POST "https://n8n.yourcompany.com/webhook/smm/events" \
     -H "Content-Type: application/json" \
     -d '{
       "subscriber": {
         "id": "sub_109283",
         "name": "Jane Doe"
       },
       "message": {
         "text": "Hello, do you offer custom enterprise pricing for your services?"
       },
       "channel": "instagram",
       "event_type": "dm"
     }'
   ```
5. **Verify AI Processing**:
   - `SMM-M1` logs the inbound message in Supabase `messages`.
   - `SMM-M2` processes the inquiry. Because pricing is a custom topic, it routes to `SMM-M4` for human escalation and alerts the team with a suggested AI draft.
