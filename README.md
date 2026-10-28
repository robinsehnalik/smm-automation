# Social Media Management (SMM) Automation — Implementation Guide & Overview

> [!IMPORTANT]
> ### ⚠️ Disclaimer & Production Recommendation: Use External Schedulers & Messaging Aggregators
>
> While this repository includes direct integrations with native social media APIs (Meta Graph API for Instagram/Facebook, LinkedIn UGC API, and X API v2), **using approved third-party scheduling and messaging platforms is the STRONGLY RECOMMENDED workflow for production**.
>
> **Why?**
> 1. **Strict Permission Gating & App Reviews:** Major social platforms (especially Meta/Instagram and LinkedIn) enforce exhaustive, slow, and frequently rejected app review processes for publishing (`pages_manage_posts`, `instagram_content_publish`) and direct messaging permissions (`instagram_manage_messages`).
> 2. **Sudden API Deprecation & Rate Limiting:** Platforms frequently alter API endpoints, impose tight quota throttling on independent developer apps, or block direct automated API calls to user-facing messaging endpoints.
> 3. **Account Safety:** Automating direct posts or auto-replies via custom developer tokens carries a significant risk of trigger-happy shadowbanning or account suspension if platform algorithms detect non-whitelisted API patterns.
>
> **Recommended Production Setup:**
> - **Outbound Publishing (`SMM-P3`):** Route posts through established scheduling aggregators such as **Ayrshare, Buffer, Publer, or Metricool**. n8n sends an HTTP request with the generated copy and media assets to the scheduler API, which reliably manages official partner tokens, platform compliance, rate limits, and video/image transcoding.
> - **Inbound Community Messaging (`SMM-M1` through `SMM-M4`):** Connect an official messaging platform like **ManyChat** (for Meta-approved 24h Instagram/Facebook DM automation) or a unified helpdesk such as **Gorgias, Zendesk, or Front**. Let ManyChat or Gorgias handle the webhook connection and messaging compliance, while n8n serves as the AI brain via webhooks (`SMM-M2`) to generate brand-grounded replies and safety evaluations.

---

## 1. System Overview
The **Social Media Management (SMM) Automation** system operates two synchronized pipelines: an **Outbound Content Pipeline** (intake ideas, generate tailored copy per platform via LLM, enforce human review/approval, schedule and publish to LinkedIn, X, Meta) and an **Inbound Community Management Pipeline** (capture webhooks for comments and DMs, deduplicate events, evaluate brand risk and sentiment, and either auto-reply or escalate to human staff).

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
                       [SMM-P3 Scheduler & Publisher] ── Minute cron publishes
                                       │                 (Direct API or Aggregator)
                                       ▼
                       [SMM-P4 Notifications & Metrics]

PIPELINE B: Inbound Community Management
[Social Webhook (DM / Comment)] ──► [SMM-M1 Event Trigger Intake]
(Direct Webhook or ManyChat)                    │
                                                ▼
                                   [SMM-M2 LLM Response Builder]
                                                │
                               ┌────────────────┴────────────────┐
                               ▼                                 ▼
                     [Confidence >= 0.85]              [Sensitive / Low Conf]
                               │                                 │
                               ▼                                 ▼
                   [SMM-M3 Messenger Dispatch]      [SMM-M4 Human Escalation]
                   (Direct API or ManyChat)         (Email or Helpdesk Ticket)
```

---

## 2. Workflows Included (`n8n-workflows/`)

| File | Name | Trigger | Primary Purpose |
| :--- | :--- | :--- | :--- |
| [`smm-p1-content-intake.json`](./n8n-workflows/smm-p1-content-intake.json) | SMM-P1 Content Intake | Webhook (`POST /smm/idea-intake`) | Captures raw post idea, target platforms, and media URLs. |
| [`smm-p2-llm-platform-variants.json`](./n8n-workflows/smm-p2-llm-platform-variants.json) | SMM-P2 LLM Platform Variants | Webhook (`POST /smm/variants`) | Generates platform-tailored copy, hashtags, and formatting. |
| [`smm-p3-scheduler-publisher.json`](./n8n-workflows/smm-p3-scheduler-publisher.json) | SMM-P3 Scheduler & Publisher | Cron (`* * * * *` Every min) | Locks due posts and publishes via platform APIs or scheduling aggregators. |
| [`smm-p4-notifications-metrics.json`](./n8n-workflows/smm-p4-notifications-metrics.json) | SMM-P4 Notifications & Metrics | Cron (`0 18 * * *` Daily) | Polls published posts and saves daily impression/engagement snapshots. |
| [`smm-m1-event-trigger-intake.json`](./n8n-workflows/smm-m1-event-trigger-intake.json) | SMM-M1 Event Trigger Intake | Webhook (`POST /smm/events`) | Ingests platform comments/DMs (or ManyChat webhooks) and dedupes external IDs. |
| [`smm-m2-llm-response-builder.json`](./n8n-workflows/smm-m2-llm-response-builder.json) | SMM-M2 LLM Response Builder | Webhook (`POST /smm/response-builder`) | Evaluates risk, generates reply draft, routes to auto-reply vs human. |
| [`smm-m3-messenger-dispatch.json`](./n8n-workflows/smm-m3-messenger-dispatch.json) | SMM-M3 Messenger Dispatch | Webhook (`POST /smm/dispatch`) | Enforces hourly rate limits and dispatches reply to platform API. |
| [`smm-m4-notifications-escalation.json`](./n8n-workflows/smm-m4-notifications-escalation.json) | SMM-M4 Notifications & Escalation | Webhook (`POST /smm/escalate`) | Alerts owner via email or opens ticket in helpdesk software. |
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
  event_type TEXT DEFAULT 'comment',
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

| Variable | Description | Example Value |
| :--- | :--- | :--- |
| `LINK_TO_YOUR_N8N_INSTANCE` | Host URL of n8n | `https://n8n.yourcompany.com` |
| `LINK_TO_YOUR_SUPABASE_URL` | Supabase API endpoint | `https://xyzproject.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase Service Role key | `eyJhbGciOiJIUzI1NiIsIn...` |
| `OPENAI_API_KEY` | OpenAI API key for `gpt-4o` | `sk-proj-...` |
| `LINKEDIN_OAUTH_TOKEN` | LinkedIn Member or Page Access Token (Direct mode) | `AQV...` |
| `LINKEDIN_ORGANIZATION_URN` | LinkedIn Organization URN | `urn:li:organization:12345678` |
| `X_API_BEARER_TOKEN` | X (Twitter) API v2 Bearer token (Direct mode) | `AAAA...` |
| `META_PAGE_ACCESS_TOKEN` | Meta Graph API Page Access Token (Direct mode) | `EAA...` |
| `RESEND_API_KEY` | Resend API key for alerts | `re_...` |
| `SYSTEM_SENDER_EMAIL` | Sender address | `social-alerts@yourdomain.com` |
| `OWNER_NOTIFICATION_EMAIL` | Owner address for approvals/escalations | `owner@yourdomain.com` |
| `ADMIN_NOTIFICATION_EMAIL` | Admin address for error alerts | `admin@yourdomain.com` |
| `LINK_TO_YOUR_DASHBOARD` | Dashboard frontend URL | `https://dashboard.yourdomain.com` |

> **Note for Aggregator Setup**: When using an external scheduler like Ayrshare or Buffer, replace `LINKEDIN_OAUTH_TOKEN`, `X_API_BEARER_TOKEN`, and `META_PAGE_ACCESS_TOKEN` with your aggregator API key (e.g., `AYRSHARE_API_KEY`), and point the HTTP Request node in `SMM-P3` directly to the aggregator's `/post` endpoint.

---

## 5. Deployment & Testing Steps

1. **Import & Activate Workflows**:
   - Import all 9 JSON files from [`n8n-workflows/`](./n8n-workflows/).
   - Activate `SMM-ERR`, `SMM-P4`, `SMM-P3`, down to `SMM-P1`.
2. **Submit Content Idea**:
   ```bash
   curl -X POST "https://n8n.yourcompany.com/webhook/smm/idea-intake" \
     -H "Content-Type: application/json" \
     -d '{
       "topic": "Automating Customer Support with AI Agents",
       "key_message": "How modern teams cut resolution time by 70% using hybrid RAG and human escalation.",
       "target_platforms": ["linkedin", "x"]
     }'
   ```
3. **Approve and Publish**:
   - In Supabase `post_variants`, approve the generated variants by updating `status` to `scheduled` and setting `publish_at = now()`.
   - Within 60 seconds, `SMM-P3` picks up the scheduled record, dispatches it to LinkedIn/X (or your external scheduler), and marks status as `published`.

