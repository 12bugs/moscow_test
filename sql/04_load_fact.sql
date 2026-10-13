-- =====================================================================
-- Наполнение факта: подстановка суррогатных ключей вместо натуральных
-- INNER JOIN — где пропусков нет (ошибка = потеря строк, ловится проверками)
-- LEFT JOIN + COALESCE(…, 0) — где пропуски возможны (unknown member)
-- =====================================================================

INSERT INTO dwh.fact_lot (
    lot_id, purchase_id, contract_id,
    publish_date_key, protocol_date_key, method_key, status_key,
    grbs_key, customer_key, kpgz_key, supplier_key,
    row_type, law, procurement_level, nmck_bucket,
    nmck, contract_price, savings, reduction_pct,
    bids_submitted, bids_admitted, duration_days, n_rows, n_contracts, joint_size,
    has_contract, is_per_unit, is_joint, is_reduction_valid, is_date_invalid,
    is_contract_conflict, is_nmck_missing, no_bids, is_single_bid, is_single_admitted,
    source_row_num
)
SELECT
    s.lot_id, s.purchase_id, s.contract_id,
    COALESCE(dp.date_key, 0),
    COALESCE(dr.date_key, 0),
    m.method_key,
    st.status_key,
    g.grbs_key,
    cu.customer_key,
    COALESCE(k.kpgz_key, 0),
    COALESCE(sp.supplier_key, 0),
    s.row_type, s.law, s.procurement_level, s.nmck_bucket,
    s.nmck, s.contract_price, s.savings, s.reduction_pct,
    s.bids_submitted, s.bids_admitted, s.duration_days, s.n_rows, s.n_contracts, s.joint_size,
    s.has_contract, s.is_per_unit, s.is_joint, s.is_reduction_valid, s.is_date_invalid,
    s.is_contract_conflict, s.is_nmck_missing, s.no_bids, s.is_single_bid, s.is_single_admitted,
    s.source_row_num
FROM stg.lots_clean s
JOIN      dwh.dim_method   m  ON m.method_name    = s.method
JOIN      dwh.dim_status   st ON st.status_name   = s.status
JOIN      dwh.dim_grbs     g  ON g.grbs_id        = s.grbs_id
JOIN      dwh.dim_customer cu ON cu.customer_id   = s.customer_id
LEFT JOIN dwh.dim_kpgz     k  ON k.kpgz_code      = s.kpgz_code
LEFT JOIN dwh.dim_supplier sp ON sp.supplier_name = s.winner_name_norm
LEFT JOIN dwh.dim_date     dp ON dp.full_date     = s.publish_date::DATE
LEFT JOIN dwh.dim_date     dr ON dr.full_date     = s.protocol_date::DATE;

ANALYZE dwh.fact_lot;   -- обновить статистику для планировщика запросов