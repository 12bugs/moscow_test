-- Выполняется один раз при первом создании базы
CREATE SCHEMA IF NOT EXISTS stg;   -- сырые данные
CREATE SCHEMA IF NOT EXISTS dwh;   -- справочники и факты
CREATE SCHEMA IF NOT EXISTS mart;  -- витрины для BI