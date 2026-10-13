-- =====================================================================
-- Наполнение справочников из stg.lots_clean
-- Суррогатные ключи: ROW_NUMBER() по натуральному ключу → детерминированно
-- Ключ 0 «Не указан» — только там, где в данных бывают пропуски
-- =====================================================================

-- Способ определения поставщика
INSERT INTO dwh.dim_method (method_key, method_name, method_group, is_competitive)
SELECT ROW_NUMBER() OVER (ORDER BY method_group, method),
       method,
       method_group,
       method_group <> 'Единственный поставщик'
FROM (SELECT DISTINCT method, method_group FROM stg.lots_clean) s;

-- Статус лота
INSERT INTO dwh.dim_status (status_key, status_name)
SELECT ROW_NUMBER() OVER (ORDER BY status), status
FROM (SELECT DISTINCT status FROM stg.lots_clean) s;

-- Комплекс
INSERT INTO dwh.dim_complex (complex_key, complex_name)
SELECT ROW_NUMBER() OVER (ORDER BY complex), complex
FROM (SELECT DISTINCT complex FROM stg.lots_clean) s;

-- ГРБС → комплекс. Если у ГРБС окажется 2 комплекса, UNIQUE(grbs_id) не даст загрузить
INSERT INTO dwh.dim_grbs (grbs_key, grbs_id, complex_key)
SELECT ROW_NUMBER() OVER (ORDER BY s.grbs_id), s.grbs_id, c.complex_key
FROM (SELECT DISTINCT grbs_id, complex FROM stg.lots_clean) s
JOIN dwh.dim_complex c ON c.complex_name = s.complex;

-- Заказчик
INSERT INTO dwh.dim_customer (customer_key, customer_id)
SELECT ROW_NUMBER() OVER (ORDER BY customer_id), customer_id
FROM (SELECT DISTINCT customer_id FROM stg.lots_clean) s;

-- КПГЗ (+ unknown member)
INSERT INTO dwh.dim_kpgz (kpgz_key, kpgz_code, kpgz_name, kpgz_l1_code)
VALUES (0, '—', 'Не указан', '—');

INSERT INTO dwh.dim_kpgz (kpgz_key, kpgz_code, kpgz_name, kpgz_l1_code)
SELECT ROW_NUMBER() OVER (ORDER BY kpgz_code), kpgz_code, kpgz_name, SPLIT_PART(kpgz_code, '.', 1)
FROM (SELECT DISTINCT kpgz_code, kpgz_name FROM stg.lots_clean WHERE kpgz_code IS NOT NULL) s;

-- Поставщик-победитель (+ unknown member)
INSERT INTO dwh.dim_supplier (supplier_key, supplier_name) VALUES (0, 'Не указан');

INSERT INTO dwh.dim_supplier (supplier_key, supplier_name)
SELECT ROW_NUMBER() OVER (ORDER BY winner_name_norm), winner_name_norm
FROM (SELECT DISTINCT winner_name_norm FROM stg.lots_clean WHERE winner_name_norm IS NOT NULL) s;