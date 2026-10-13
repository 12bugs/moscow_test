-- =====================================================================
-- Пользователь для Superset: только чтение и только схема mart.
-- Выполняется ОДИН раз, от имени ETL-пользователя (того, кто создаёт витрины).
-- Пароль после запуска смените: ALTER ROLE superset_ro PASSWORD '…';
-- =====================================================================

CREATE ROLE superset_ro LOGIN PASSWORD 'change_me';

GRANT CONNECT ON DATABASE dwh TO superset_ro;
GRANT USAGE   ON SCHEMA mart  TO superset_ro;

-- Права на витрины, которые существуют сейчас
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO superset_ro;

-- Права на витрины, которые будут созданы в будущем.
-- Нужны потому, что load.py пересоздаёт витрины при каждом запуске,
-- а обычный GRANT удаляется вместе с объектом.
ALTER DEFAULT PRIVILEGES IN SCHEMA mart GRANT SELECT ON TABLES TO superset_ro;

-- Доступа к stg и dwh НЕТ намеренно: представления выполняются с правами
-- своего владельца (ETL-пользователя), поэтому BI видит данные только через витрины.