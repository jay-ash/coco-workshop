---
name: prd-to-dynamic-table-plan
description: "Turn PRD-style requirement workbooks (source onboarding, business rules, column mappings) into a traceable change plan for one existing Snowflake Dynamic Table. Read-only: plans, never mutates. Use when: a PRD/requirements XLSX must be applied to a target DT such as a Silver layer table. Triggers: PRD to dynamic table, requirements to DT plan, onboard new source into DT, apply business rules to silver, PRD impact analysis, requirements workbook."
---

# PRD → Dynamic Table Change Plan

Reads a PRD-style workbook and the live state of a target Dynamic Table, then returns a
fixed-format plan that says what must change, what belongs elsewhere, and what is still
undecided. It deliberately stops before any DDL — implementation is handed to `$dynamic-tables`
only after the user has resolved the blocking questions.

## When to Use

- A requirements/PRD workbook describes new sources, fields, or rules for an existing DT.
- The user wants an impact analysis or implementation plan, not an immediate change.

Not for: creating a brand-new pipeline with no PRD (use `$dynamic-tables` directly), or
non-XLSX inputs (see Step 1).

## Inputs

| Input | Required | Notes |
|---|---|---|
| `prd_path` | yes | Local path to a `.xlsx` workbook. |
| `target_dynamic_table` | yes | Fully qualified `DB.SCHEMA.NAME`. If the user gives a bare name, resolve it and confirm — do not guess the schema. |
| `sheets` | no | Sheet names to include. Default: all sheets. |

## Workflow

### Step 1: Validate inputs

- Only `.xlsx` is supported in this version. For `.csv`, `.docx`, `.pdf`, etc., say so and ask
  whether to proceed anyway with best-effort reading, or convert first. Reason: the sheet-role
  detection below assumes tabular sheets; other formats lose structure and traceability.
- Confirm the file exists and the DT exists (`SHOW DYNAMIC TABLES LIKE '<NAME>' IN SCHEMA <DB>.<SCHEMA>`).

**⚠️ STOP** if either input is missing or ambiguous.

### Step 2: Read the workbook

Use the `read` tool on `prd_path` (it renders every sheet as a table). For each sheet record:
- **Role**: `source_onboarding`, `business_rules`, `column_mapping`, or `other`, inferred from headers
  (e.g. "Source System / Go-Live" → onboarding; "Rule ID / Rule Description" → rules;
  "Source column / Target column" → mapping).
- **Row IDs** (e.g. `BR-003`, `SRC-2025-004`). If a sheet has no ID column, cite `Sheet!row N`.
- **Status / decision fields** — capture verbatim; words like "NEEDS DECISION", "TBD", "pending",
  "open question" become open questions, never decisions.

State the detected roles to the user. If a sheet's role is unclear, list it as `other` and say so.

### Step 3: Capture current DT state (read-only)

```sql
USE DATABASE <DB>;  -- required for INFORMATION_SCHEMA functions
SHOW DYNAMIC TABLES LIKE '<NAME>' IN SCHEMA <DB>.<SCHEMA>;
SELECT "text","target_lag","refresh_mode","refresh_mode_reason","scheduling_state","warehouse","rows"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
DESCRIBE DYNAMIC TABLE <DB>.<SCHEMA>.<NAME>;
SELECT inputs FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY())
WHERE qualified_name = '<DB>.<SCHEMA>.<NAME>';
```

From the definition (`text`), extract: current sources/UNION branches, literal identifiers
(e.g. `SOURCE_SYSTEM`), CASE mappings, dedup logic, and output columns.

### Step 4: Verify referenced sources

For every source system the PRD mentions, look for its bronze/landing table
(`SHOW TABLES LIKE '%<SOURCE>%' IN SCHEMA ...`; if unsure where, use the
`snowflake-object-discovery` subagent). Record: exists?, row count, `change_tracking` (must be ON
for incremental refresh), `is_external` (external tables cannot feed a DT), and columns
(`DESCRIBE TABLE`) so mapped fields can be checked.

### Step 5: Diff requirements vs. current state

Classify each PRD row into exactly one bucket:
- **Target DT change** — alters this DT's SQL or properties.
- **Out of layer** — explicitly or logically belongs to another layer (Gold, a DMF, Bronze load).
- **No change** — already implemented; cite where in the current definition.
- **Informational** — context only.

Then cross-check rules against each other and against the live state. Look especially for:
- Rules whose literal SQL contradicts their intent (e.g. a dedup partition that spans all sources).
- Rules depending on something declared out of scope (e.g. a USD threshold with no FX at this layer).
- Property changes unsafe in the current graph (e.g. `TARGET_LAG = DOWNSTREAM` with no downstream DT means the table stops refreshing).
- Mapped columns missing from bronze, or value domains not covered by a CASE (what happens to unlisted values?).
- Dates in the PRD that are already past relative to today.

### Step 6: Produce the plan

Return the Output (below). Draft SQL is a proposal only — label it `-- DRAFT, not executed`.

**⚠️ STOP**: Present the plan. Ask the user to resolve blocking questions. Do not run DDL.

### Step 7: Optional handoff

Only if the user asks to implement: load `$dynamic-tables` (CREATE-OR-ALTER intent) and pass the
approved plan plus the user's answers. Its own approval checkpoints still apply.

## Surfacing Assumptions and Open Questions

The plan is only useful if a reviewer can tell fact from inference. Guessing silently turns a
planning document into a hidden design decision.

- **Tag every claim**: `[PRD: <row id>]`, `[Verified: <query/object>]`, or `[Assumption]`.
- **An assumption must state its default and its impact**: "Assume dedup applies only to the BAAN
  branch — if wrong, valid SAP/Workday invoices sharing a number would be dropped."
- **Never resolve a conflict by picking a side.** Present both readings and who owns the decision
  (owner names usually appear in the PRD's decision column).
- **Blocking vs. non-blocking**: a question is *blocking* if any answer would change the target DT's
  SQL or properties. Everything else is non-blocking and can be decided during build.
- **Prefer verification to assumption**: if a question can be answered by a read-only query
  (does the column exist? is change tracking on?), run it instead of asking.
- **Quote, don't paraphrase, decision text** when it is ambiguous ("Current recommendation: leave
  as-is" is not a decision).
- **Preserve unknowns**: if the workbook is silent on something the DT needs (e.g. column mapping
  for a new source), list it as missing rather than inventing a mapping.

## Output

Always return these sections in this order, even if a section is "None found":

1. **Summary** — target DT, PRD file + sheets read (with detected roles), current DT state in one line
   (lag, refresh mode, scheduling state, source count), and counts per bucket.
2. **New source systems** — table: source, request ID, bronze table, exists?, rows, change tracking,
   status/blockers (e.g. legal, go-live).
3. **Changes to the target DT** — table: #, change, PRD ref, evidence tag, blocking question # (if any).
4. **Out-of-layer rules** — rule, where it belongs, why.
5. **Conflicts & risks** — each with both readings and the consequence.
6. **Open questions** — numbered; each marked **Blocking** / **Non-blocking**, with suggested owner
   and the default you'd use if forced.
7. **Draft SQL & validation** — `-- DRAFT, not executed` changes (e.g. new UNION ALL branch, CASE
   additions) plus a rerunnable validation query (row counts per source vs. bronze).

End with: "Nothing was executed against the target table."

## Example

**User:** "Use `$prd-to-dynamic-table-plan` with `prd_path=requirements/ap_invoices_phase2.xlsx`
and `target_dynamic_table=COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES`."

**Abbreviated output:**

> **1. Summary** — Sheets: `Source Onboarding` (source_onboarding), `Business Rules` (business_rules),
> `Column Mapping` (column_mapping). DT: lag 1 hour, ADAPTIVE, ACTIVE, 2 sources (SAP, ORACLE).
> 6 target-DT changes, 4 out-of-layer, 0 no-change.
>
> **2. New sources**
> | Source | Request | Bronze table | Exists | Rows | Change tracking | Blockers |
> |---|---|---|---|---|---|---|
> | BAAN | SRC-2025-003 | SOURCE_DATA.BRONZE_BAAN_AP_INVOICES | yes [Verified] | 10 | **OFF** | none |
> | WORKDAY | SRC-2025-004 | SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES | yes [Verified] | 10 | **OFF** | Legal DPA-2025-0041 pending [PRD] |
>
> **3. Changes** — e.g. "Add BAAN UNION ALL branch with `'BAAN' AS SOURCE_SYSTEM` [PRD: BR-007]";
> "Extend status CASE: POSTED→APPROVED, In Review→PENDING [PRD: BR-001]";
> "Dedup Baan on INVOICE_NUMBER by latest CREATED_AT [PRD: BR-003] — see Q2".
>
> **4. Out of layer** — BR-002 FX conversion → Gold; BR-004 >$500k flag → DMF; BR-006 CoA → Gold Phase 2.
>
> **5. Conflicts** — BR-009 sets `TARGET_LAG = DOWNSTREAM`, but no downstream DT exists
> [Verified: graph history] → the table would stop refreshing.
>
> **6. Open questions**
> 1. **Blocking** — Keep a time-based lag until Gold exists? (Owner: Engineering. Default: keep 1 hour.)
> 2. **Blocking** — BR-003 partitions on INVOICE_NUMBER across all sources; apply to BAAN branch only?
>    (Owner: Karen van der Berg. Default: BAAN only.)
> 3. **Blocking** — BR-004 needs USD equivalent but FX is out of scope (BR-002). (Owner: Tom Walsh.)
> 4. Non-blocking — BR-005 payment terms marked "NEEDS DECISION"; decision date 2025-06-20 has passed.
>
> **7. Draft SQL** — `-- DRAFT, not executed` UNION ALL branches + the per-source count proof query.
>
> Nothing was executed against the target table.

## Stopping Points

- ✋ Step 1: missing/ambiguous inputs or unsupported file type
- ✋ Step 6: plan presented; user resolves blocking questions
- ✋ Step 7: implementation only on explicit request, via `$dynamic-tables` approvals
