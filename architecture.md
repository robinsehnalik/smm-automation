# Automation Architecture — Social Media Management (SMM) System

The **SMM Automation** is a two-pipeline system built on **n8n**, **Supabase (Postgres + pgvector)**, an **LLM API**, and the **social platform APIs**.

- **Posting Pipeline**: ideas and posts live in a content calendar, an LLM tailors each post per platform, schedulers publish, and notifications confirm the result.
- **Messaging Pipeline**: comments, DMs, and follows trigger context-aware responses generated from company data, delivered through the platform messengers, with escalation to a human when needed.


> [!IMPORTANT]
> ### ⚠️ Recommended Production Path: External Schedulers & Messaging Aggregators
> Direct integration with native social platform APIs (Meta Graph API, X API v2, LinkedIn UGC API) is fully documented and provided in these workflows. However, **due to strict and unpredictable app review processes, tight permission gating (e.g. Meta `instagram_manage_messages`, `pages_manage_posts`), aggressive rate limiting, and the persistent risk of platform developer app bans, utilizing certified third-party aggregators (such as Ayrshare, Buffer, Publer, or Metricool for publishing, and ManyChat, Gorgias, or Zendesk for messaging) is the strongly recommended operational path for production deployments.**

---

## 1. Architectural Principles

1. **Brand Consistency**: All generation is grounded in a stored **brand profile** (voice, do/don't list, products, FAQs). The LLM never improvises facts about the company.
2. **Human Authorization Where It Matters**: Posts follow a configurable approval policy (auto, approve-first, or approve-first-N). Replies to sensitive topics (complaints, pricing, legal, refunds) always escalate.
3. **Platform-Native Output**: One idea becomes several variants, each respecting the platform's limits, format, hashtag norms, and media specs.
4. **Safe Automation on Social Platforms**: Rate limits, platform messaging windows, and automation policies are enforced in the workflows. Reply volume is capped to avoid account flags.
5. **Idempotent Publishing**: A post variant is published at most once; the platform post ID is stored immediately and checked before any retry.
6. **Observability**: Every publish and every auto-reply is logged with its input, generated text, confidence, and outcome.

---

## 2. High-Level System Architecture

```mermaid
flowchart TD
    subgraph Owner["Owner"]
        Calendar["Posting Calendar (Dashboard)"]
        Approve["Approval and Escalation Inbox"]
    end

    subgraph Data["Supabase Postgres"]
        Ideas[("content_ideas, posts, post_variants")]
        Brand[("brand_profile, knowledge_chunks (pgvector)")]
        Conv[("conversations, messages, interactions")]
    end

    subgraph Posting["Posting Pipeline"]
        P1["SMM-P1 Content Intake"]
        P2["SMM-P2 LLM Platform Variants"]
        P3["SMM-P3 Scheduler and Publisher"]
        P4["SMM-P4 Notifications and Metrics"]
    end

    subgraph Messaging["Messaging Pipeline"]
        M1["SMM-M1 Event Trigger Intake"]
        M2["SMM-M2 LLM Response Builder"]
        M3["SMM-M3 Messenger Dispatch"]
        M4["SMM-M4 Notifications and Escalation"]
    end

    subgraph LLM["LLM Layer"]
        VarLLM["Variant Writer"]
        RespLLM["Response Writer with Retrieval"]
    end

    subgraph Platforms["Social Platforms"]
        IG["Instagram"]
        FB["Facebook"]
        LI["LinkedIn"]
        X["X"]
        Other["Other channels"]
    end

    Calendar --> Ideas
    Ideas --> P1
    P1 --> P2
    P2 --> VarLLM
    VarLLM --> Brand
    P2 --> Ideas
    Ideas -->|"Approved and due"| P3
    P3 --> Platforms
    P3 --> P4
    P4 --> Approve
    P4 --> Ideas

    Platforms -->|"Webhooks: comment, DM, follow"| M1
    M1 --> Conv
    Conv --> M2
    M2 --> RespLLM
    RespLLM --> Brand
    M2 -->|"Confident and safe"| M3
    M2 -->|"Sensitive or low confidence"| M4
    M3 --> Platforms
    M3 --> M4
    M4 --> Approve
```

---

## 3. Core Data Flows & Sequence Diagrams

### 3.1. Posting Pipeline

```mermaid
sequenceDiagram
    autonumber
    actor Owner as Owner
    participant DB as Supabase
    participant P2 as SMM-P2 Variant Generator
    participant LLM as LLM
    participant UI as Dashboard Approval
    participant P3 as SMM-P3 Scheduler
    participant Plat as Platform APIs
    participant P4 as SMM-P4 Notifications

    Owner->>DB: Add idea or post { topic, key message, media, target platforms, date }
    DB->>P2: Trigger: idea ready for variants
    P2->>DB: Load brand profile, platform specs, past top posts
    loop For each target platform
        P2->>LLM: Tailor copy, length, tone, hashtags, CTA for platform
        LLM-->>P2: Variant text + media notes
        P2->>P2: Validate (char limits, banned words, required links, brand rules)
        P2->>DB: INSERT post_variant { status: pending_approval }
    end
    P2->>UI: Variants appear in Approval Inbox
    Owner->>UI: Approve, edit, or reject each variant
    UI->>DB: status = scheduled

    P3->>DB: Every minute: select variants WHERE status = scheduled AND publish_at <= now
    P3->>DB: Lock row (status = publishing)
    P3->>Plat: Publish variant
    alt Success
        Plat-->>P3: platform_post_id, URL
        P3->>DB: status = published, store platform_post_id
    else Failure
        P3->>DB: status = failed, error stored, retry with backoff
    end
    P3->>P4: Result
    P4->>Owner: Notification (published link or failure alert)
    P4->>DB: Later: pull engagement metrics into post_metrics
```

### 3.2. Messaging Pipeline

```mermaid
sequenceDiagram
    autonumber
    actor User as Follower / Customer
    participant Plat as Platform
    participant M1 as SMM-M1 Intake
    participant DB as Supabase
    participant M2 as SMM-M2 Response Builder
    participant LLM as LLM
    participant M3 as SMM-M3 Dispatch
    participant M4 as SMM-M4 Escalation
    actor Owner as Owner

    User->>Plat: Comment, DM, or follow
    Plat->>M1: Webhook event
    M1->>M1: Verify signature, dedupe event ID
    M1->>DB: Upsert conversation, store message
    M1->>M2: Pass event context

    M2->>M2: Classify event type, intent, sentiment, risk level
    alt Spam, abuse, or blocked topic
        M2->>DB: Log and ignore, optionally hide or report
    else Needs response
        M2->>DB: Retrieve brand profile + relevant knowledge chunks
        M2->>LLM: Generate response grounded in retrieved company data
        LLM-->>M2: { reply, confidence, topics_used, needs_human }
        alt confidence high AND needs_human = false AND within rate limits
            M2->>M3: Send reply
            M3->>Plat: Post reply or send DM
            M3->>DB: Log message as sent
            M3->>M4: Informational notification
        else Sensitive or low confidence
            M2->>M4: Escalate with draft reply
            M4->>Owner: Notification with draft, approve or edit
            Owner->>DB: Approve or write own reply
            DB->>M3: Dispatch approved reply
        end
    end

    Note over M2,Plat: New follower triggers a templated welcome DM only if allowed by platform policy and enabled in config
```

### 3.3. Post Variant State Machine

```mermaid
stateDiagram-v2
    [*] --> idea: Idea added to calendar
    idea --> generating: Variants requested
    generating --> pending_approval: Variants validated
    pending_approval --> scheduled: Approved
    pending_approval --> rejected: Rejected or needs rewrite
    rejected --> generating: Regenerate with feedback
    scheduled --> publishing: Publish time reached
    publishing --> published: Platform confirms
    publishing --> failed: Error after retries
    failed --> scheduled: Manual retry
    published --> [*]
```

---

## 4. Workflow Catalog (n8n)

| ID | Workflow | Trigger | Key Actions |
| :--- | :--- | :--- | :--- |
| **SMM-P1** | Content Intake | New row in `content_ideas` / calendar | Validate idea, attach brand context, queue for variants |
| **SMM-P2** | LLM Platform Variants | Idea marked ready | Generate and validate one variant per platform, route to approval |
| **SMM-P3** | Scheduler & Publisher | Schedule (every minute) | Select due variants, lock, publish, store platform IDs, retry |
| **SMM-P4** | Notifications & Metrics | Publish result, daily schedule | Notify owner, pull engagement metrics |
| **SMM-M1** | Event Trigger Intake | Platform webhooks (comment, DM, follow) | Verify, dedupe, store conversation |
| **SMM-M2** | LLM Response Builder | New inbound message | Classify, retrieve company data, generate reply, decide auto vs escalate |
| **SMM-M3** | Messenger Dispatch | Approved or auto reply | Respect rate limits, send via platform API, log |
| **SMM-M4** | Notifications & Escalation | Escalation or send result | Notify owner, show draft in inbox |
| **SMM-ERR** | Error Handler | n8n Error Trigger | Alert owner, log failing node |

### 4.1. Platform Variant Rules (editable in `platform_specs`)

| Platform | Typical Adaptation |
| :--- | :--- |
| **LinkedIn** | Longer, professional tone, insight-led opening, few hashtags |
| **Instagram** | Visual-first caption, hook in first line, hashtag block, emoji per brand rules |
| **Facebook** | Conversational, link preview friendly, community tone |
| **X** | Short, punchy, thread split when over the limit |

Exact limits and media specs are stored in config and checked by the validator rather than hardcoded in prompts.

### 4.2. Response Decision Policy

| Condition | Action |
| :--- | :--- |
| Simple FAQ, answer found in knowledge base, confidence high | Auto-reply |
| Compliment or positive comment | Short on-brand reply or reaction |
| Pricing, quote, custom request | Reply with booking link and notify owner |
| Complaint, refund, legal, health, or negative sentiment | Escalate, no auto-reply |
| No relevant knowledge retrieved | Escalate with note "no grounded answer" |
| Spam, abuse | Ignore or moderate, log |
| New follower | Optional welcome DM, only where platform policy permits |

---

## 5. Database Architecture

```mermaid
erDiagram
    content_ideas {
        UUID id PK
        TEXT topic
        TEXT key_message
        JSONB media_refs
        TEXT[] target_platforms
        TIMESTAMPTZ target_date
        TEXT status
    }

    posts {
        UUID id PK
        UUID idea_id FK
        TEXT approval_policy "auto | approve"
    }

    post_variants {
        UUID id PK
        UUID post_id FK
        TEXT platform
        TEXT body
        JSONB media
        TIMESTAMPTZ publish_at
        TEXT status "pending_approval | scheduled | publishing | published | failed | rejected"
        TEXT platform_post_id
        TEXT error
    }

    post_metrics {
        UUID id PK
        UUID variant_id FK
        INT impressions
        INT likes
        INT comments
        INT shares
        TIMESTAMPTZ captured_at
    }

    brand_profile {
        UUID id PK
        TEXT voice
        JSONB dos_donts
        JSONB blocked_topics
        JSONB platform_specs
    }

    knowledge_chunks {
        UUID id PK
        TEXT source "FAQ, product, policy"
        TEXT content
        VECTOR embedding
    }

    conversations {
        UUID id PK
        TEXT platform
        TEXT external_user_id
        TEXT status "open | escalated | resolved"
    }

    messages {
        UUID id PK
        UUID conversation_id FK
        TEXT direction "inbound | outbound"
        TEXT event_type "comment | dm | follow"
        TEXT body
        NUMERIC confidence
        BOOLEAN auto_sent
        TEXT external_event_id "unique, for dedupe"
    }

    content_ideas ||--o{ posts : "becomes"
    posts ||--o{ post_variants : "has variants"
    post_variants ||--o{ post_metrics : "measured by"
    conversations ||--o{ messages : "contains"
```

---

## 6. External Integrations

| Service | Role | Used By |
| :--- | :--- | :--- |
| **Social platform APIs** (Meta Graph API for Instagram and Facebook, LinkedIn, X, others) | Publishing, comments, DMs, follower events | SMM-P3, SMM-M1, SMM-M3 |
| **LLM API** | Variant writing, intent classification, response writing | SMM-P2, SMM-M2 |
| **Supabase + pgvector** | Calendar, conversations, brand data, retrieval | All workflows |
| **Notifications** (Resend email, Slack or Telegram) | Publish results, escalations, failures | SMM-P4, SMM-M4 |
| **Retool Dashboard** | Posting calendar, approval inbox, conversation view | Owner |

> Platform API access, permissions, app review, and automation rules differ per platform and change over time. Verify current requirements for each platform before go-live.

---

## 7. Security & Reliability Architecture

- **Retrieval-grounded replies**: The response LLM receives only retrieved knowledge chunks and the brand profile. If retrieval returns nothing relevant, the workflow escalates instead of answering.
- **Prompt-injection defense**: Incoming comments and DMs are untrusted data, delimited in the prompt, and cannot alter instructions, reveal prompts, or trigger actions.
- **Webhook security**: Platform signature verification on every inbound event; `external_event_id` uniqueness prevents double processing.
- **Rate limiting & caps**: Per-platform reply caps per hour, per-user reply limits, and cooldowns avoid spam-like behavior.
- **Token management**: OAuth tokens stored in the n8n credential vault with expiry monitoring and a refresh-failure alert.
- **Idempotent publishing**: Row lock before publish; `platform_post_id` checked before any retry.
- **Kill switch**: A `smm_enabled` flag per pipeline in config instantly pauses auto-replies or publishing without editing workflows.

| Failure Scenario | Response |
| :--- | :--- |
| Publish API error | Retry with backoff, then mark `failed` and alert |
| Token expired | Alert owner, pause the platform's workflows |
| LLM invalid or empty output | Retry once, then escalate or hold for manual writing |
| Duplicate webhook delivery | Ignored via `external_event_id` |
| Reply flood or suspicious spike | Auto-pause auto-replies, alert owner |

---

## 8. Repository / Workspace File Map

```text
automation-smm/
├── architecture-smm.md
├── workflows/
│   ├── smm-p1-content-intake.json
│   ├── smm-p2-llm-platform-variants.json
│   ├── smm-p3-scheduler-publisher.json
│   ├── smm-p4-notifications-metrics.json
│   ├── smm-m1-event-trigger-intake.json
│   ├── smm-m2-llm-response-builder.json
│   ├── smm-m3-messenger-dispatch.json
│   ├── smm-m4-notifications-escalation.json
│   └── smm-err-error-handler.json
├── prompts/
│   ├── variant-writer.md
│   ├── intent-classifier.md
│   └── response-writer.md
├── knowledge/                          # Source documents embedded into knowledge_chunks
├── sql/schema.sql
└── docs/
    ├── brand-voice.md
    └── escalation-policy.md
```

---

## 9. Environment & Configuration

| Name | Purpose |
| :--- | :--- |
| `LLM_API_KEY` | Variants and responses |
| `META_APP_SECRET`, `META_PAGE_TOKENS`, `LINKEDIN_TOKEN`, `X_API_KEYS` | Platform access (n8n credentials) |
| `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` | Database |
| `AUTO_REPLY_ENABLED`, `AUTO_PUBLISH_ENABLED` | Kill switches |
| `REPLY_CONFIDENCE_THRESHOLD`, `MAX_REPLIES_PER_HOUR` | Tunable safety limits |
| `NOTIFY_CHANNEL`, `OWNER_EMAIL` | Notifications |
