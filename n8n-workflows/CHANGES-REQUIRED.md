# Node-Level Implementation Requirements for SMM n8n Workflows

In accordance with system policy (Rule 0.3: *"Never fabricate n8n workflow JSON. Edit existing JSON only where straightforward and keep it valid... If you cannot edit safely, leave the file unchanged and describe the exact node-level edits in n8n-workflows/CHANGES-REQUIRED.md"*), this document specifies the precise node configurations, branching rules, and operational requirements for the Social Media Management workflows.

---

## 1. SMM-POST-01 Variant Generator: Single Regeneration Loop

The baseline workflow [`smm-post-01-variant-generator.json`](./smm-post-01-variant-generator.json) extracts the topic, generates platform copy via OpenAI, validates length/media rules in code, and writes back to the Content Calendar.

### Required Regeneration Architecture
To minimize manual copyediting while avoiding infinite LLM retry loops, a single regeneration loop should be inserted around the validation node:

```
[Extract & Validate Input] ──► [LLM Variant Generator] ──► [Strict Code Validation]
                                      ▲                              │
                                      │ (If invalid & attempt == 1)   │
                                      └──────── [Loop Back Node] ────┤
                                                                     ▼ (Valid or attempt >= 2)
                                                      [Update Content Calendar]
```

#### Node A: IF Validation Passed
* **Node Type**: `n8n-nodes-base.if`
* **Conditions**:
  * Boolean `{{ $json.is_valid }}` equals `true` OR Number `{{ $json.attempt }}` is greater than or equal to `2`.
* **True Branch**: Connect to `Update Content Calendar Record`
  * If `is_valid` is true: `Status: ready_for_approval`, `ValidationNotes: ""`
  * If `is_valid` is false (failed twice): `Status: needs_edit`, `ValidationNotes: {{ $json.validation_notes }}`
* **False Branch (Invalid on First Attempt)**: Connect to **Node B**.

#### Node B: Format Regeneration Feedback
* **Node Type**: `n8n-nodes-base.code`
* **Name**: `Prepare Regeneration Prompt`
* **Logic**:
  ```javascript
  const data = $input.item.json;
  return {
    json: {
      ...data,
      attempt: 2,
      regeneration_prompt: `The previous copy generated failed validation checks:\n${data.validation_notes}\n\nPlease regenerate the copy for LinkedIn, X, and Instagram, strictly complying with the length and media rules.`
    }
  };
  ```
* **Connection**: Routes back to `LLM Platform Variant Generator` with user prompt containing `regeneration_prompt`.

---

## 2. SMM-POST-02 Approval Dispatcher: Atomic Claim & Error Handling

The baseline workflow [`smm-post-02-approval-dispatcher.json`](./smm-post-02-approval-dispatcher.json) handles the approval trigger and vendor dispatch.

### Node-Level Dispatch Safeguards
1. **Double-Scheduling Prevention**:
   * Pre-condition: Check that `Status == 'approved'` and `AyrsharePostIds` is empty. If already scheduled or missing approval, abort immediately.
2. **Atomic Status Claim (`scheduling`)**:
   * Before calling the Ayrshare API, immediately update Airtable record to `Status = 'scheduling'`. This prevents parallel webhook triggers from making duplicate calls to Ayrshare.
3. **Minimum Lead Time Enforcement**:
   * Calculate difference between `PublishAt` and current timestamp.
   * If `PublishAt < now + MIN_SCHEDULE_LEAD_MINUTES (default 10 minutes)`:
     * Do NOT call Ayrshare.
     * Update Airtable record to `Status = 'failed'` with `Error = 'PublishAt lead time must be at least 10 minutes in the future'`.
4. **No Unsafe Retries**:
   * If Ayrshare API returns an error (HTTP 4xx/5xx), catch the error via n8n's "Continue on Fail" option.
   * Immediately update Airtable to `Status = 'failed'` and record the vendor error message in `Error`.
   * **Never automatically retry a failed POST request** without verifying whether a post ID was assigned, to prevent double-posting.

---

## 3. SMM-POST-03 Status Reconciler: Reconciliation Architecture

The baseline workflow [`smm-post-03-status-reconciler.json`](./smm-post-03-status-reconciler.json) runs on a daily schedule (`0 4 * * *`).

### Operational Logic
1. **Fetch Overdue Scheduled Posts**:
   * Filter formula: `AND(Status='scheduled', IS_BEFORE(PublishAt, DATEADD(NOW(), -15, 'minute')))`
   * Retrieves posts that should have been published at least 15 minutes ago.
2. **Query Ayrshare Verification Endpoint**:
   * Call `GET https://app.ayrshare.com/api/history/byPostId?id={{ $json.ayrshare_post_id }}` (or `/api/post/:id` depending on Ayrshare tier).
3. **Reconcile Status**:
   * If Ayrshare confirms publication: Update Airtable to `Status = 'published'`.
   * If Ayrshare reports platform error or post not found: Update Airtable to `Status = 'failed'`, `Error = 'Failed post reconciliation via Ayrshare API'`.

---

## 4. SMM-MSG-01 Community Triage Pipeline: Database & Messaging Guards

The baseline workflow [`smm-msg-01-triage-pipeline.json`](./smm-msg-01-triage-pipeline.json) receives ManyChat webhooks, classifies intent, and sends canned templates.

### Additional Database Operations for Production

#### Event Claiming (Idempotency)
To prevent duplicate replies from webhook retries, insert an event claim into `bot_events` before calling the LLM:
```sql
INSERT INTO bot_events (event_key, subscriber_hash, platform, action)
VALUES ($1, $2, $3, 'claimed')
ON CONFLICT (event_key) DO NOTHING
RETURNING id;
```
If no ID is returned, the event was already claimed: abort workflow silently.

#### Muting & Rate Limit Verification
1. **Muted Check**:
   * Query `conversation_state`:
     ```sql
     SELECT paused_until, last_interaction_at
     FROM conversation_state
     WHERE subscriber_id = $1;
     ```
   * If `paused_until > now()` OR ManyChat payload has `live_chat_status === 'open'`:
     * Log `action = 'muted'` in `bot_events` and abort.
2. **Atomic Rate Limiting**:
   * Call the database function:
     ```sql
     SELECT bump_reply_counter($1, $2, 60, 5) AS allowed;
     ```
   * If `allowed` is false:
     * Send `handoff_ack` template.
     * Set `paused_until = now() + INTERVAL '24 hours'`.
     * Apply ManyChat tag `needs_human`.
     * Log `action = 'rate_limited'`.
     * Abort further processing.
