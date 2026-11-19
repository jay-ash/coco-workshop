-- =============================================================================
-- 03_silver_ap_invoices_prd_update.sql
-- PRD update: add BAAN and WORKDAY to COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
--
-- Sources of requirements:
--   sample_business_requirements_source_onboarding.csv  (SRC-2025-003 Baan, SRC-2025-004 Workday)
--   sample_business_requirements_column_mapping.csv     (Baan + Workday column mappings)
--   sample_business_requirements_business_rules.csv     (BR-001 .. BR-010)
-- See also: notes/02_prd_change_plan.md
--
-- Applied 2026-11-19 via CREATE OR ALTER (EXPLAIN CHANGES predicted REINITIALIZE,
-- no failure). Manual refresh: REINITIALIZE SUCCEEDED, 50 rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Updated Dynamic Table
-- -----------------------------------------------------------------------------
CREATE OR ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES
  TARGET_LAG = '1 hour' REFRESH_MODE = AUTO INITIALIZE = ON_CREATE WAREHOUSE = COCO_WORKSHOP_WH
AS
SELECT 'SAP' AS SOURCE_SYSTEM, INVOICE_ID, INVOICE_NUMBER, VENDOR_ID, VENDOR_NAME,
       INVOICE_DATE, DUE_DATE, INVOICE_AMOUNT, CURRENCY_CODE,
       PAYMENT_TERMS AS PAYMENT_TERMS_RAW,
       CASE PAYMENT_TERMS WHEN 'NET30' THEN 'NET30' WHEN 'NET60' THEN 'NET60' END AS PAYMENT_TERMS,
       PO_NUMBER, LINE_DESCRIPTION, GL_ACCOUNT, COST_CENTER,
       CAST(CASE APPROVAL_STATUS WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END AS VARCHAR(20)) AS APPROVAL_STATUS,
       CREATED_AT,
       SAP_COMPANY_CODE AS COMPANY_CODE, SAP_DOCUMENT_TYPE,
       CAST(NULL AS VARCHAR(20)) AS ORACLE_SOURCE,
       APPROVAL_STATUS AS APPROVAL_STATUS_RAW
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES
UNION ALL
SELECT 'ORACLE', INV_ID, INV_NUM, SUPPLIER_ID, SUPPLIER_NAME, INV_DATE, PAYMENT_DUE_DATE,
       TOTAL_AMOUNT, CURRENCY, TERMS_CODE,
       CASE TERMS_CODE WHEN 'N30' THEN 'NET30' WHEN 'N60' THEN 'NET60' END,
       PURCHASE_ORDER, DESCRIPTION, ACCOUNT_CODE, DEPT_CODE,
       CAST(CASE STATUS WHEN 'VALIDATED' THEN 'APPROVED' WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END AS VARCHAR(20)),
       CREATION_DATE, ORACLE_ORG_ID, CAST(NULL AS VARCHAR(10)), ORACLE_SOURCE, STATUS
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES
UNION ALL
SELECT 'BAAN', BAN_INVOICE_ID, BAN_INVOICE_REF, BAN_VENDOR_CODE, BAN_VENDOR_DESC, BAN_INV_DATE, BAN_PAY_DATE,
       BAN_AMOUNT, BAN_CURR, BAN_PAY_TERMS,
       CASE BAN_PAY_TERMS WHEN 'N30' THEN 'NET30' WHEN 'N60' THEN 'NET60' END,
       BAN_PO_REF, BAN_LINE_DESC, BAN_GL_CODE, BAN_COST_CTR,
       CAST(CASE BAN_STATUS WHEN 'POSTED' THEN 'APPROVED' WHEN 'APPROVED' THEN 'APPROVED' WHEN 'PENDING' THEN 'PENDING' END AS VARCHAR(20)),
       BAN_CREATED, CAST(NULL AS VARCHAR(10)), CAST(NULL AS VARCHAR(10)), CAST(NULL AS VARCHAR(20)), BAN_STATUS
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES
QUALIFY ROW_NUMBER() OVER (PARTITION BY BAN_INVOICE_REF ORDER BY BAN_CREATED DESC, BAN_INVOICE_ID DESC) = 1  -- BR-003, Baan only
UNION ALL
SELECT 'WORKDAY', WD_INVOICE_ID, WD_INVOICE_NUM, WD_SUPPLIER_ID, WD_SUPPLIER_NAME, WD_INVOICE_DATE, WD_DUE_DATE,
       WD_AMOUNT, WD_CURRENCY, WD_PAY_TERMS,
       CASE WD_PAY_TERMS WHEN 'Net 30' THEN 'NET30' WHEN 'Net 60' THEN 'NET60' END,
       WD_PO_NUMBER, WD_MEMO, WD_LEDGER_ACCOUNT, WD_COST_CENTER,
       CAST(CASE WD_APPROVAL_STATUS WHEN 'Approved' THEN 'APPROVED' WHEN 'In Review' THEN 'PENDING' END AS VARCHAR(20)),
       WD_CREATED_DATE, CAST(NULL AS VARCHAR(10)), CAST(NULL AS VARCHAR(10)), CAST(NULL AS VARCHAR(20)), WD_APPROVAL_STATUS
FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES;

-- Optional: apply immediately instead of waiting for the 1-hour lag
-- ALTER DYNAMIC TABLE COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES REFRESH;


-- -----------------------------------------------------------------------------
-- 2. How the new sources map into the common schema
-- -----------------------------------------------------------------------------
-- Silver column        BAAN source         WORKDAY source       Transform
-- -------------------  ------------------  -------------------  ---------------------------------
-- SOURCE_SYSTEM        'BAAN'              'WORKDAY'            literal per branch (BR-007)
-- INVOICE_ID           BAN_INVOICE_ID      WD_INVOICE_ID        direct
-- INVOICE_NUMBER       BAN_INVOICE_REF     WD_INVOICE_NUM       direct; Baan dedup key (BR-003)
-- VENDOR_ID            BAN_VENDOR_CODE     WD_SUPPLIER_ID       direct (supplier -> vendor)
-- VENDOR_NAME          BAN_VENDOR_DESC     WD_SUPPLIER_NAME     direct (UTF-8 native)
-- INVOICE_DATE         BAN_INV_DATE        WD_INVOICE_DATE      direct
-- DUE_DATE             BAN_PAY_DATE        WD_DUE_DATE          direct
-- INVOICE_AMOUNT       BAN_AMOUNT          WD_AMOUNT            direct, original currency (BR-002)
-- CURRENCY_CODE        BAN_CURR            WD_CURRENCY          direct
-- PAYMENT_TERMS_RAW    BAN_PAY_TERMS       WD_PAY_TERMS         original value kept
-- PAYMENT_TERMS        N30/N60 -> NET30/60 Net 30/60 -> NET30/60 normalized (existing Silver pattern)
-- PO_NUMBER            BAN_PO_REF          WD_PO_NUMBER         direct, nullable
-- LINE_DESCRIPTION     BAN_LINE_DESC       WD_MEMO              direct, nullable
-- GL_ACCOUNT           BAN_GL_CODE         WD_LEDGER_ACCOUNT    direct, no CoA cross-map (BR-006)
-- COST_CENTER          BAN_COST_CTR        WD_COST_CENTER       direct
-- APPROVAL_STATUS      POSTED/APPROVED ->  Approved -> APPROVED  BR-001; unlisted values -> NULL
--                      APPROVED; PENDING   In Review -> PENDING
-- APPROVAL_STATUS_RAW  BAN_STATUS          WD_APPROVAL_STATUS   original value kept
-- CREATED_AT           BAN_CREATED (UTC)   WD_CREATED_DATE (UTC) direct
-- COMPANY_CODE, SAP_DOCUMENT_TYPE, ORACLE_SOURCE: NULL for both (SAP/Oracle-only columns)
-- Dropped at Silver: BAN_COMPANY, WD_TENANT_ID (BR-008)
--
-- Also in this definition: Oracle VALIDATED now maps to APPROVED (BR-001 fix).


-- -----------------------------------------------------------------------------
-- 3. Assumptions requiring engineering review
-- -----------------------------------------------------------------------------
-- A1. WORKDAY is included per request, but the PRD lists it as blocked on legal
--     review of DPA-2025-0041 (SRC-2025-004). Confirm sign-off before production use.
-- A2. BR-008 says to drop system-specific columns, but the existing Silver keeps
--     COMPANY_CODE / SAP_DOCUMENT_TYPE / ORACLE_SOURCE. Kept for backward compatibility
--     (NULL for new sources). Owner: David Kim.
-- A3. Payment terms: PRD says "keep as-is, normalize in Gold" (open decision, due
--     2025-06-20). Existing Silver already normalizes; extended that pattern and kept
--     PAYMENT_TERMS_RAW so no data is lost. Owners: Sarah Chen / David Kim.
-- A4. BR-003 dedup applied to the Baan branch only (PRD's literal SQL partitions across
--     all sources, which could drop valid invoices from other systems sharing a number).
-- A5. Unlisted status values map to NULL; APPROVAL_STATUS_RAW preserves the original.
-- A6. EXPLAIN CHANGES insight QUALIFY_RANK_NOT_TOP_LEVEL: the Baan QUALIFY is nested in a
--     UNION branch, so refreshes can't use the fastest incremental path. Acceptable at
--     current volume; if Baan grows, move dedup to a separate upstream DT.
-- A7. SOURCE_SYSTEM widened VARCHAR(6) -> VARCHAR(7) to fit 'WORKDAY'.
-- A8. TARGET_LAG kept at '1 hour'. BR-009's DOWNSTREAM would stop refreshes until a
--     Gold DT exists.
-- A9. Change tracking was enabled on BRONZE_BAAN / BRONZE_WORKDAY by the DT; keep it on.
-- A10. Data observations vs PRD: Baan cost centers look like BC-ENG (not BC-XX/BC-XXX);
--      "always positive" vs "negative credit memos" for Baan amounts is contradictory
--      (0 negatives today). No Silver logic depends on either.


-- -----------------------------------------------------------------------------
-- 4. Validation queries (results on 2026-11-19 noted inline)
-- -----------------------------------------------------------------------------
USE DATABASE COCO_WORKSHOP;

-- 4.1 Row reconciliation per source vs bronze (Baan vs deduped bronze)
--     Result: SAP 15/15, ORACLE 15/15, BAAN 10/10, WORKDAY 10/10 -> all PASS
WITH s AS (SELECT SOURCE_SYSTEM, COUNT(*) n FROM PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY 1),
b AS (
  SELECT 'SAP' src, COUNT(*) n FROM SOURCE_DATA.BRONZE_SAP_AP_INVOICES
  UNION ALL SELECT 'ORACLE', COUNT(*) FROM SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES
  UNION ALL SELECT 'BAAN', COUNT(DISTINCT BAN_INVOICE_REF) FROM SOURCE_DATA.BRONZE_BAAN_AP_INVOICES
  UNION ALL SELECT 'WORKDAY', COUNT(*) FROM SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES)
SELECT COALESCE(s.SOURCE_SYSTEM, b.src) src, b.n bronze, s.n silver,
       IFF(EQUAL_NULL(b.n, s.n), 'PASS', 'FAIL') status
FROM s FULL OUTER JOIN b ON s.SOURCE_SYSTEM = b.src ORDER BY 1;

-- 4.2 Status / payment-terms / currency domains per source
--     Result: Workday Approved->APPROVED (8), In Review->PENDING (2); Net 30/60 -> NET30/60;
--             Baan POSTED->APPROVED (7); Oracle VALIDATED->APPROVED (11)
SELECT SOURCE_SYSTEM, APPROVAL_STATUS_RAW, APPROVAL_STATUS,
       PAYMENT_TERMS_RAW, PAYMENT_TERMS, CURRENCY_CODE, COUNT(*) n
FROM PIPELINE_LAB.SILVER_AP_INVOICES GROUP BY ALL ORDER BY 1, 2, 4, 6;

-- 4.3 Quality checks (expect total = 50 and every other column = 0)
--     Result: 50, 0, 0, 0, 0, 0, 0
SELECT COUNT(*) total,
       COUNT(*) - COUNT(DISTINCT SOURCE_SYSTEM, INVOICE_ID) dup_ids,
       COUNT_IF(SOURCE_SYSTEM = 'BAAN') - COUNT(DISTINCT IFF(SOURCE_SYSTEM = 'BAAN', INVOICE_NUMBER, NULL)) baan_dup_numbers,
       COUNT_IF(INVOICE_ID IS NULL OR INVOICE_NUMBER IS NULL OR VENDOR_ID IS NULL OR INVOICE_DATE IS NULL
                OR INVOICE_AMOUNT IS NULL OR CURRENCY_CODE IS NULL OR GL_ACCOUNT IS NULL
                OR COST_CENTER IS NULL OR CREATED_AT IS NULL) missing_required,
       COUNT_IF(APPROVAL_STATUS IS NULL) unmapped_status,
       COUNT_IF(PAYMENT_TERMS IS NULL) unmapped_terms,
       COUNT_IF(APPROVAL_STATUS NOT IN ('APPROVED', 'PENDING')) bad_status
FROM PIPELINE_LAB.SILVER_AP_INVOICES;

-- 4.4 Refresh health
--     Result: ACTIVE, ADAPTIVE, lag 1 hour; last refresh REINITIALIZE SUCCEEDED
SHOW DYNAMIC TABLES LIKE 'SILVER_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.PIPELINE_LAB;
SELECT "target_lag", "refresh_mode", "refresh_mode_reason", "scheduling_state", "rows"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT refresh_start_time, state, refresh_action, refresh_trigger, state_message
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
  NAME => 'COCO_WORKSHOP.PIPELINE_LAB.SILVER_AP_INVOICES'))
ORDER BY refresh_start_time DESC LIMIT 5;

-- 4.5 Change tracking on all bronze inputs (expect ON for all four)
--     Result: ON for SAP, ORACLE, BAAN, WORKDAY
SHOW TABLES LIKE 'BRONZE_%_AP_INVOICES' IN SCHEMA COCO_WORKSHOP.SOURCE_DATA;
SELECT "name", "change_tracking" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
