-- =====================================================================
-- Сверка хранилища со staging: каждая строка — одна проверка
-- expected = что в stg.lots_clean, actual = что в dwh
-- =====================================================================
WITH s AS (SELECT * FROM stg.lots_clean),
     f AS (SELECT * FROM dwh.fact_lot)
SELECT 'Число лотов' AS check_name,
       (SELECT COUNT(*) FROM s)::NUMERIC AS expected,
       (SELECT COUNT(*) FROM f)::NUMERIC AS actual
UNION ALL
-- деньги сверяем с тем же округлением до копеек, что и при записи в NUMERIC(18,2)
SELECT 'Сумма НМЦК, руб',
       (SELECT SUM(ROUND(nmck::NUMERIC, 2)) FROM s),
       (SELECT SUM(nmck)                    FROM f)
UNION ALL
SELECT 'Сумма экономии, руб',
       (SELECT SUM(ROUND(savings::NUMERIC, 2)) FROM s),
       (SELECT SUM(savings)                    FROM f)
UNION ALL
SELECT 'Конкурентных лотов',
       (SELECT COUNT(*) FROM s WHERE row_type = 'competitive'),
       (SELECT COUNT(*) FROM f WHERE row_type = 'competitive')
UNION ALL
SELECT 'Лотов без КПГЗ → ключ 0',
       (SELECT COUNT(*) FROM s WHERE kpgz_code IS NULL),
       (SELECT COUNT(*) FROM f WHERE kpgz_key = 0)
UNION ALL
SELECT 'Лотов без победителя → ключ 0',
       (SELECT COUNT(*) FROM s WHERE winner_name_norm IS NULL),
       (SELECT COUNT(*) FROM f WHERE supplier_key = 0)
UNION ALL
SELECT 'Лотов без даты публикации → ключ 0',
       (SELECT COUNT(*) FROM s WHERE publish_date IS NULL),
       (SELECT COUNT(*) FROM f WHERE publish_date_key = 0)
UNION ALL
SELECT 'Лотов с одной заявкой',
       (SELECT COUNT(*) FROM s WHERE is_single_bid),
       (SELECT COUNT(*) FROM f WHERE is_single_bid);