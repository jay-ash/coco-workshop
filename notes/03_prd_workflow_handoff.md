# PRD Workflow Handoff — SILVER_AP_INVOICES (Baan + Workday onboarding)

Date: 2026-11-19 · Target: `COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES` · Connection used: `DEMO` (role ACCOUNTADMIN)

All files below are in this repo but **untracked in git** — commit them together so the review has one changeset.

## 1. Artifacts to save

| # | Path | Purpose | Reviewer action |
|---|---|---|---|
| 1 | `sample_business_requirements_source_onboarding.csv` | PRD input: new sources (SRC-2025-003 Baan, SRC-2025-004 Workday) | Check source status / blockers |
| 2 | `sample_business_requirements_column_mapping.csv` | PRD input: Baan + Workday → Silver column mapping | Primary spec for the DDL |
| 3 | `sample_business_requirements_business_rules.csv` | PRD input: BR-001 … BR-010 | Cross-check rules vs DDL |
| 4 | `.cortex/skills/prd-to-dynamic-table-plan/SKILL.md` | The PRD Evaluator project skill (`$prd-to-dynamic-table-plan`) | Reuse for future PRDs (see §4) |
| 5 | `notes/02_prd_change_plan.md` | Skill output: mapping, open questions, decisions, Baan-only DDL + results | Review decisions Q1–Q5. **Note:** Workday was excluded there; superseded by #6 |
| 6 | `sql/03_silver_ap_invoices_prd_update.sql` | **Current deployed DDL** (SAP, Oracle, Baan, Workday), mapping summary, assumptions A1–A10, validation queries with results | Main review artifact; rerun §4 queries |
| 7 | `notes/03_prd_workflow_handoff.md` | This file | — |

Related setup files (pre-existing, not part of the change): `00_snowday_setup.sql`, `00_sample_data.sql`, `01_demo_reset.sql`. `01_demo_reset.sql` was not reviewed in this workflow — check what it drops before running it.

## 2. What changed in Snowflake

| Object | Change |
|---|---|
| `PIPELINE_LAB.SILVER_AP_INVOICES` | `CREATE OR ALTER`: + BAAN branch (dedup BR-003), + WORKDAY branch, Oracle `VALIDATED→APPROVED`, + column `APPROVAL_STATUS_RAW VARCHAR(20)`, `SOURCE_SYSTEM` VARCHAR(6)→(7). Lag 1 hour, ADAPTIVE, 30 → 50 rows. Two manual refreshes, both `REINITIALIZE` SUCCEEDED |
| `SOURCE_DATA.BRONZE_BAAN_AP_INVOICES` | Change tracking OFF → ON (set by the DT) |
| `SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES` | Change tracking OFF → ON (set by the DT) |

## 3. Review checklist (open items for engineering)

- [ ] **Workday legal sign-off** (DPA-2025-0041) — deployed on request despite PRD blocker (A1).
- [ ] **BR-008 conflict** — SAP/Oracle-specific columns kept for compatibility (A2, owner David Kim).
- [ ] **Payment terms** — normalized at Silver + raw kept; PRD decision still open (A3, Sarah Chen / David Kim).
- [ ] **Dedup scope** — Baan branch only (A4).
- [ ] **Unmapped statuses → NULL**, raw preserved (A5).
- [ ] **Perf insight** `QUALIFY_RANK_NOT_TOP_LEVEL` — acceptable now; split dedup into its own DT if Baan volume grows (A6).
- [ ] **Downstream consumers** of `APPROVAL_STATUS`: Oracle `VALIDATED` now reads `APPROVED`.
- [ ] **TARGET_LAG** stays `1 hour` until a Gold DT exists (A8).

## 4. Rerun the checks

```sql
-- Run sections 4.1–4.5 of sql/03_silver_ap_invoices_prd_update.sql
-- Expected: all sources PASS (15/15/10/10), quality counters 0, ACTIVE/ADAPTIVE, change tracking ON x4
```

Optional freshness proof before checking: `ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES REFRESH;`

## 5. Reuse the PRD Evaluator skill

```
$prd-to-dynamic-table-plan
prd_path: <path/to/prd.xlsx>
target_dynamic_table: <DB.SCHEMA.DT_NAME>
```

- v1 supports **`.xlsx` only**; for CSVs it asks first (this run used "all three CSVs" best-effort).
- It is read-only: returns a plan with `[PRD]` / `[Verified]` / `[Assumption]` tags and blocking questions, then hands off to `$dynamic-tables` (dry-run with `EXPLAIN CHANGES`, approval, apply).
- Lessons from this run worth folding into the skill: add CSV-set support; always run `EXPLAIN CHANGES` to catch type widening in `UNION ALL` branches (CASE expressions need explicit casts); check `DYNAMIC_TABLE_INSIGHTS` in the dry-run output.
- Not yet shared to the Snowflake account (publish was declined). To share: `cortex skill catalog publish .cortex/skills/prd-to-dynamic-table-plan -c DEMO --discoverable --roles PUBLIC --description '…'`.

## 6. Rollback (pre-change definition, captured 2026-11-19)

Reverting reinitializes the DT and drops `APPROVAL_STATUS_RAW`; dry-run with `EXPLAIN CHANGES` first. Change tracking on Baan/Workday bronze can stay ON.

```sql
CREATE OR ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
  TARGET_LAG = '1 hour' REFRESH_MODE = AUTO INITIALIZE = ON_CREATE WAREHOUSE = COCO_WORKSHOP_WH
AS
SELECT 'SAP' AS SOURCE_SYSTEM, INVOICE_ID, INVOICE_NUMBER, VENDOR_ID, VENDOR_NAME,
       INVOICE_DATE, DUE_DATE, INVOICE_AMOUNT, CURRENCY_CODE,
       PAYMENT_TERMS AS PAYMENT_TERMS_RAW,
       CASE PAYMENT_TERMS WHEN 'NET30' THEN 'NET30' WHEN 'NET60' THEN 'NET60' END AS PAYMENT_TERMS,
       PO_NUMBER, LINE_DESCRIPTION, GL_ACCOUNT, COST_CENTER, APPROVAL_STATUS, CREATED_AT,
       SAP_COMPANY_CODE AS COMPANY_CODE, SAP_DOCUMENT_TYPE,
       CAST(NULL AS VARCHAR(20)) AS ORACLE_SOURCE
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES
UNION ALL
SELECT 'ORACLE', INV_ID, INV_NUM, SUPPLIER_ID, SUPPLIER_NAME,
       INV_DATE, PAYMENT_DUE_DATE, TOTAL_AMOUNT, CURRENCY,
       TERMS_CODE,
       CASE TERMS_CODE WHEN 'N30' THEN 'NET30' WHEN 'N60' THEN 'NET60' END,
       PURCHASE_ORDER, DESCRIPTION, ACCOUNT_CODE, DEPT_CODE, STATUS, CREATION_DATE,
       ORACLE_ORG_ID, CAST(NULL AS VARCHAR(10)), ORACLE_SOURCE
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES;
```
