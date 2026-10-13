-- =====================================================================
-- Витрины (mart) для Superset. Только представления (VIEW):
-- данные не дублируются, витрина всегда соответствует текущему dwh.
-- Скрипт идемпотентен.
-- =====================================================================

DROP VIEW IF EXISTS mart.v_kpi                       CASCADE;
DROP VIEW IF EXISTS mart.v_reduction_by_participants CASCADE;
DROP VIEW IF EXISTS mart.v_benchmark                 CASCADE;
DROP VIEW IF EXISTS mart.v_kpgz_concentration        CASCADE;
DROP VIEW IF EXISTS mart.v_top_suppliers             CASCADE;
DROP VIEW IF EXISTS mart.v_customers                 CASCADE;
DROP VIEW IF EXISTS mart.v_monthly                   CASCADE;
DROP VIEW IF EXISTS mart.v_noncompetitive_share      CASCADE;
DROP VIEW IF EXISTS mart.v_lots                      CASCADE;


-- ---------------------------------------------------------------------
-- 1. Широкая витрина: факт + все справочники. Основной датасет Superset.
--    Здесь же — аналитическое правило подозрительной экономии.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_lots AS
SELECT
    f.lot_id,
    f.row_type,
    CASE f.row_type WHEN 'competitive' THEN 'Конкурентная процедура'
                    WHEN 'direct'      THEN 'Единственный поставщик'
                    ELSE                    'Плановая позиция' END        AS row_type_name,
    f.law,
    m.method_name, m.method_group, m.is_competitive,
    s.status_name,
    c.complex_name,
    g.grbs_id,
    cu.customer_id,
    k.kpgz_code, k.kpgz_name, k.kpgz_l1_code,
    sp.supplier_name,
    dp.full_date   AS publish_date,
    dp.month_start AS publish_month,
    dp.quarter     AS publish_quarter,
    f.nmck_bucket,
    f.nmck, f.contract_price, f.savings, f.reduction_pct,
    f.bids_submitted, f.bids_admitted, f.duration_days,
    CASE WHEN f.bids_admitted IS NULL THEN NULL
         WHEN f.bids_admitted >= 5    THEN '5+'
         ELSE f.bids_admitted::TEXT END                                   AS participants,
    f.is_single_bid, f.is_single_admitted, f.no_bids,
    f.is_per_unit, f.is_joint, f.is_reduction_valid, f.is_nmck_missing,
    -- Правило витрины: при 0–1 допущенном участнике снижение > 25% нетипично
    -- (66% таких лотов — ровно 0%), а эти лоты дают 2/3 всей «экономии».
    -- Не удаляем, а выделяем, чтобы суммы можно было показать с ними и без них.
    (f.savings IS NOT NULL AND f.bids_admitted <= 1 AND f.reduction_pct > 25) AS is_savings_suspicious,
    CASE WHEN f.bids_admitted <= 1 AND f.reduction_pct > 25 THEN NULL
         ELSE f.savings END                                               AS savings_clean
FROM dwh.fact_lot f
JOIN dwh.dim_method   m  USING (method_key)
JOIN dwh.dim_status   s  USING (status_key)
JOIN dwh.dim_grbs     g  USING (grbs_key)
JOIN dwh.dim_complex  c  ON c.complex_key = g.complex_key
JOIN dwh.dim_customer cu USING (customer_key)
JOIN dwh.dim_kpgz     k  USING (kpgz_key)
JOIN dwh.dim_supplier sp USING (supplier_key)
JOIN dwh.dim_date     dp ON dp.date_key = f.publish_date_key;


-- ---------------------------------------------------------------------
-- 2. KPI — одна строка с главными цифрами для верхней панели дашборда
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_kpi AS
WITH comp AS (
    SELECT * FROM mart.v_lots WHERE row_type = 'competitive'
),
benchmark AS (   -- медианное снижение при двух участниках — «нормальная» конкуренция
    SELECT (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reduction_pct))::NUMERIC AS red_2
    FROM comp WHERE bids_admitted = 2 AND is_reduction_valid AND NOT is_per_unit
)
SELECT
    (SELECT COUNT(*) FROM mart.v_lots)                                          AS lots_total,
    (SELECT COUNT(*) FROM comp)                                                 AS lots_competitive,
    (SELECT ROUND(SUM(nmck) / 1e9, 1) FROM mart.v_lots)                         AS nmck_total_bln,
    (SELECT ROUND(SUM(nmck) FILTER (WHERE row_type = 'direct') / SUM(nmck), 3)
       FROM mart.v_lots WHERE row_type IN ('competitive', 'direct'))            AS share_nmck_direct,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY bids_submitted) FROM comp) AS median_bids,
    (SELECT ROUND(AVG(is_single_bid::INT), 3) FROM comp)                        AS share_single_bid,
    (SELECT ROUND(AVG(no_bids::INT), 3) FROM comp)                              AS share_no_bids,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reduction_pct)
       FROM comp WHERE is_reduction_valid)                                      AS median_reduction_pct,
    (SELECT ROUND(SUM(savings_clean) / 1e9, 1) FROM comp)                       AS savings_clean_bln,
    (SELECT ROUND(SUM(savings) FILTER (WHERE is_savings_suspicious) / 1e9, 1) FROM comp) AS savings_suspicious_bln,
    -- Недополученная экономия: лоты с 1 участником, если бы снижение было как при 2
    (SELECT ROUND(SUM(nmck * b.red_2 / 100) / 1e9, 1)
       FROM comp, benchmark b
      WHERE bids_admitted = 1 AND NOT is_per_unit AND NOT is_nmck_missing)      AS lost_savings_bln,
    -- то же без мегалотов (НМЦК ≥ 1 млрд): 162 лота дают 85% оценки выше
    (SELECT ROUND(SUM(nmck * b.red_2 / 100) / 1e9, 1)
       FROM comp, benchmark b
      WHERE bids_admitted = 1 AND NOT is_per_unit AND NOT is_nmck_missing
        AND nmck < 1e9)                                                         AS lost_savings_excl_mega_bln,
    (SELECT red_2 FROM benchmark)                                               AS median_reduction_2_participants;


-- ---------------------------------------------------------------------
-- 3. Главная зависимость: снижение по числу допущенных участников
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_reduction_by_participants AS
SELECT participants,
       COUNT(*)                                                                 AS lots,
       ROUND(AVG(reduction_pct), 2)                                             AS avg_reduction,
       ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY reduction_pct))::NUMERIC, 2)              AS q25,
       ROUND((PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY reduction_pct))::NUMERIC, 2)              AS median,
       ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY reduction_pct))::NUMERIC, 2)              AS q75
FROM mart.v_lots
WHERE row_type = 'competitive' AND is_reduction_valid AND NOT is_per_unit
  AND participants IS NOT NULL
GROUP BY participants;


-- ---------------------------------------------------------------------
-- 4. Сравнительный анализ: комплексы и ГРБС против рынка.
--    excess_single — доля лотов с 1 участником СВЕРХ ожидаемой для такого
--    набора КПГЗ (стандартизация: убирает эффект состава закупок)
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_benchmark AS
WITH base AS (
    SELECT complex_name, grbs_id, reduction_pct, is_reduction_valid, nmck, savings_clean,
           is_single_admitted::INT                                              AS single,
           AVG(is_single_admitted::INT) OVER (PARTITION BY kpgz_code)           AS expected_single
    FROM mart.v_lots
    WHERE row_type = 'competitive'
),
grouped AS (
    SELECT 'Комплекс' AS level, complex_name AS name, * FROM base
    UNION ALL
    SELECT 'ГРБС', grbs_id::TEXT || ' (' || complex_name || ')', * FROM base
)
SELECT level, name,
       COUNT(*)                                                                 AS lots,
       ROUND(SUM(nmck) / 1e9, 2)                                                AS nmck_bln,
       ROUND(AVG(single), 3)                                                    AS share_single,
       ROUND(AVG(expected_single), 3)                                           AS expected_single,
       ROUND(AVG(single - expected_single), 3)                                  AS excess_single,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reduction_pct)
           FILTER (WHERE is_reduction_valid))::NUMERIC, 2)                                    AS median_reduction,
       ROUND(SUM(savings_clean) / 1e9, 2)                                       AS savings_clean_bln
FROM grouped
GROUP BY level, name
HAVING COUNT(*) >= 30;      -- маленькие группы статистически ненадёжны


-- ---------------------------------------------------------------------
-- 5. Концентрация поставщиков по рынкам КПГЗ: HHI и доля лидера
--    HHI = Σ(доля поставщика, %)²: < 1500 — конкурентный рынок,
--    1500–2500 — умеренная концентрация, > 2500 — высокая
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_kpgz_concentration AS
WITH wins AS (
    SELECT kpgz_code, kpgz_name, supplier_name,
           COALESCE(SUM(COALESCE(contract_price, nmck)), 0) AS value,
           COUNT(*)                            AS lots
    FROM mart.v_lots
    WHERE row_type = 'competitive' AND supplier_name <> 'Не указан' AND kpgz_code <> '—'
    GROUP BY kpgz_code, kpgz_name, supplier_name
),
shares AS (
    SELECT *, value / NULLIF(SUM(value) OVER (PARTITION BY kpgz_code), 0) AS share
    FROM wins
)
SELECT kpgz_code, kpgz_name,
       SUM(lots)                                     AS lots,
       COUNT(*)                                      AS suppliers,
       ROUND(SUM(value) / 1e6, 1)                    AS value_mln,
       ROUND(MAX(share), 3)                          AS top1_share,
       ROUND(SUM(POWER(share * 100, 2)))             AS hhi,
       CASE WHEN SUM(POWER(share * 100, 2)) > 2500 THEN 'Высокая'
            WHEN SUM(POWER(share * 100, 2)) > 1500 THEN 'Умеренная'
            ELSE 'Низкая' END                        AS concentration
FROM shares
GROUP BY kpgz_code, kpgz_name
HAVING SUM(lots) >= 30;


-- ---------------------------------------------------------------------
-- 6. Топ поставщиков
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_top_suppliers AS
SELECT supplier_name,
       COUNT(*)                                           AS wins,
       ROUND(COALESCE(SUM(COALESCE(contract_price, nmck)), 0) / 1e6, 1) AS value_mln,
       COUNT(DISTINCT customer_id)                        AS customers,
       COUNT(DISTINCT kpgz_code)                          AS markets,
       ROUND(AVG(is_single_admitted::INT), 3)             AS share_won_alone
FROM mart.v_lots
WHERE row_type = 'competitive' AND supplier_name <> 'Не указан'
GROUP BY supplier_name;


-- ---------------------------------------------------------------------
-- 7. Заказчики: карта «объём × доля лотов с одним участником»
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_customers AS
SELECT customer_id, complex_name,
       COUNT(*)                                                                 AS lots,
       ROUND(SUM(nmck) / 1e6, 1)                                                AS nmck_mln,
       ROUND(AVG(is_single_admitted::INT), 3)                                   AS share_single,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reduction_pct)
           FILTER (WHERE is_reduction_valid))::NUMERIC, 2)                                    AS median_reduction
FROM mart.v_lots
WHERE row_type = 'competitive'
GROUP BY customer_id, complex_name
HAVING COUNT(*) >= 20;


-- ---------------------------------------------------------------------
-- 8. Динамика по месяцам публикации
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_monthly AS
SELECT publish_month, method_group,
       COUNT(*)                                                                 AS lots,
       ROUND(SUM(nmck) / 1e9, 2)                                                AS nmck_bln,
       ROUND(AVG(bids_submitted), 2)                                            AS avg_bids,
       ROUND(AVG(is_single_admitted::INT), 3)                                   AS share_single,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reduction_pct)
           FILTER (WHERE is_reduction_valid))::NUMERIC, 2)                                    AS median_reduction
FROM mart.v_lots
WHERE row_type = 'competitive' AND publish_month IS NOT NULL
GROUP BY publish_month, method_group;


-- ---------------------------------------------------------------------
-- 9. Доля закупок без конкуренции (по НМЦК) в разрезе комплексов
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_noncompetitive_share AS
SELECT complex_name,
       ROUND(SUM(nmck) FILTER (WHERE row_type = 'competitive') / 1e9, 2)        AS competitive_bln,
       ROUND(SUM(nmck) FILTER (WHERE row_type = 'direct') / 1e9, 2)             AS direct_bln,
       ROUND(SUM(nmck) FILTER (WHERE row_type = 'direct')
             / NULLIF(SUM(nmck), 0), 3)                                         AS share_direct
FROM mart.v_lots
WHERE row_type IN ('competitive', 'direct')
GROUP BY complex_name;