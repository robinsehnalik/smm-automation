# Inbound Messaging Canned Reply Templates

In the SMM community triage pipeline (`SMM-MSG-01`), **the LLM classifies intent only and never authors freeform reply text**. Responses are assembled deterministically from the pre-approved canned templates below and appended with the automated disclosure footer.

---

## 1. Intent Allowlist Templates (v1)

### `business_hours`
* **Intent ID**: `business_hours`
* **Description**: Inquiries regarding operating hours, office open times, or customer support availability.
* **Template Text**:
  ```text
  Our team is available Monday through Friday from {{BUSINESS_HOURS}} (EST). Messages received outside these hours are reviewed the next business day.
  ```

### `shipping_info`
* **Intent ID**: `shipping_info`
* **Description**: Inquiries regarding standard shipping timeframes, tracking updates, and delivery coverage.
* **Template Text**:
  ```text
  Standard domestic orders ship within {{SHIPPING_TIMEFRAME}} business days. Once your order has dispatched, a tracking link will be emailed to your order address.
  ```

### `returns_policy`
* **Intent ID**: `returns_policy`
* **Description**: Inquiries regarding return windows, exchange procedures, and return eligibility.
* **Template Text**:
  ```text
  We offer returns on eligible, unopened items within {{RETURNS_WINDOW}} days of delivery. For return authorization and step-by-step instructions, please visit our returns portal at {{RETURNS_URL}} or email {{SUPPORT_EMAIL}}.
  ```

### `catalog_link`
* **Intent ID**: `catalog_link`
* **Description**: Inquiries asking where to browse products, view collections, or check available items.
* **Template Text**:
  ```text
  You can explore our full product catalog and current collection directly at {{CATALOG_URL}}.
  ```

---

## 2. Human Escalation Acknowledgment Template

### `handoff_ack`
* **Template ID**: `handoff_ack`
* **Description**: Sent once when an inquiry is flagged as sensitive, contains unlisted intents, or requires human assistance.
* **Template Text**:
  ```text
  Thank you for reaching out. I've flagged your message for our support team so a representative can look into this personally. A team member will follow up with you here within {{HANDOFF_HOURS}} hours during standard business hours.
  ```

---

## 3. Mandatory Automated Disclosure Footer

### `AUTO_REPLY_FOOTER`
* **Description**: Mandatory footer appended to all automated direct message replies to comply with Meta Platform policies on automated interactions.
* **Text**:
  ```text


  —
  🤖 Automated Assistant | Reply 'agent' to speak with our team.
  ```

---

## 4. Default Configuration Placeholders

The variables inside the templates are populated dynamically from environment configuration:

| Placeholder | Default Value | Description |
| :--- | :--- | :--- |
| `{{BUSINESS_HOURS}}` | `9:00 AM – 6:00 PM` | Customer service hours of operation |
| `{{SHIPPING_TIMEFRAME}}` | `3–5` | Standard processing & shipping days |
| `{{RETURNS_WINDOW}}` | `30` | Return policy window in days |
| `{{RETURNS_URL}}` | `https://example.com/returns` | Public returns portal link |
| `{{CATALOG_URL}}` | `https://example.com/shop` | Main catalog URL |
| `{{SUPPORT_EMAIL}}` | `support@example.com` | Official support desk email |
| `{{HANDOFF_HOURS}}` | `24` | Expected human turnaround SLA |
