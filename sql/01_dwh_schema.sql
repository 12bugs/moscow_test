-- =====================================================================
-- Модель хранилища: схема «звезда» (с одной снежинкой ГРБС → комплекс)
-- Зерно факта: один лот
-- Скрипт идемпотентен: удаляет и создаёт таблицы заново
-- =====================================================================

DROP TABLE IF EXISTS dwh.fact_lot      CASCADE;
DROP TABLE IF EXISTS dwh.dim_date      CASCADE;
DROP TABLE IF EXISTS dwh.dim_method    CASCADE;
DROP TABLE IF EXISTS dwh.dim_status    CASCADE;
DROP TABLE IF EXISTS dwh.dim_complex   CASCADE;
DROP TABLE IF EXISTS dwh.dim_grbs      CASCADE;
DROP TABLE IF EXISTS dwh.dim_customer  CASCADE;
DROP TABLE IF EXISTS dwh.dim_kpgz      CASCADE;
DROP TABLE IF EXISTS dwh.dim_supplier  CASCADE;


-- ---------------------------------------------------------------------
-- Справочники (измерения)
-- Ключ *_key — суррогатный. Ключ 0 — «Не указан» (unknown member),
-- чтобы внешние ключи в факте никогда не были NULL.
-- ---------------------------------------------------------------------

-- Календарь. Ключ — «умный» целочисленный YYYYMMDD (стандарт для дат)
CREATE TABLE dwh.dim_date (
    date_key        INTEGER     PRIMARY KEY,         -- 20250131
    full_date       DATE        UNIQUE,              -- NULL только у ключа 0
    year            SMALLINT,
    quarter         SMALLINT,
    month           SMALLINT,
    month_name      TEXT,
    month_start     DATE,
    week_of_year    SMALLINT,
    day_of_week     SMALLINT,                        -- 1 = понедельник
    is_weekend      BOOLEAN
);

CREATE TABLE dwh.dim_method (
    method_key      SMALLINT    PRIMARY KEY,
    method_name     TEXT        NOT NULL UNIQUE,     -- исходное название способа
    method_group    TEXT        NOT NULL,            -- Аукцион / Конкурс / …
    is_competitive  BOOLEAN     NOT NULL             -- FALSE только у ед. поставщика
);

CREATE TABLE dwh.dim_status (
    status_key      SMALLINT    PRIMARY KEY,
    status_name     TEXT        NOT NULL UNIQUE
);

CREATE TABLE dwh.dim_complex (
    complex_key     SMALLINT    PRIMARY KEY,
    complex_name    TEXT        NOT NULL UNIQUE
);

-- ГРБС → комплекс: строгая иерархия (проверено: у каждого ГРБС ровно один комплекс)
CREATE TABLE dwh.dim_grbs (
    grbs_key        INTEGER     PRIMARY KEY,
    grbs_id         INTEGER     NOT NULL UNIQUE,     -- натуральный ключ из источника
    complex_key     SMALLINT    NOT NULL REFERENCES dwh.dim_complex (complex_key)
);

-- Заказчик НЕ вложен в ГРБС: у 301 заказчика встречается несколько ГРБС
CREATE TABLE dwh.dim_customer (
    customer_key    INTEGER     PRIMARY KEY,
    customer_id     INTEGER     NOT NULL UNIQUE
);

CREATE TABLE dwh.dim_kpgz (
    kpgz_key        INTEGER     PRIMARY KEY,
    kpgz_code       TEXT        NOT NULL UNIQUE,     -- 02.02.02
    kpgz_name       TEXT        NOT NULL,
    kpgz_l1_code    TEXT        NOT NULL             -- 02 — верхний уровень классификатора
);

CREATE TABLE dwh.dim_supplier (
    supplier_key    INTEGER     PRIMARY KEY,
    supplier_name   TEXT        NOT NULL UNIQUE      -- нормализованное название
);


-- ---------------------------------------------------------------------
-- Факт: один лот
-- ---------------------------------------------------------------------
CREATE TABLE dwh.fact_lot (
    -- натуральный ключ зерна + вырожденные измерения (degenerate dimensions)
    lot_id                BIGINT       PRIMARY KEY,
    purchase_id           BIGINT,
    contract_id           BIGINT,

    -- внешние ключи на справочники
    publish_date_key      INTEGER      NOT NULL REFERENCES dwh.dim_date (date_key),
    protocol_date_key     INTEGER      NOT NULL REFERENCES dwh.dim_date (date_key),
    method_key            SMALLINT     NOT NULL REFERENCES dwh.dim_method (method_key),
    status_key            SMALLINT     NOT NULL REFERENCES dwh.dim_status (status_key),
    grbs_key              INTEGER      NOT NULL REFERENCES dwh.dim_grbs (grbs_key),
    customer_key          INTEGER      NOT NULL REFERENCES dwh.dim_customer (customer_key),
    kpgz_key              INTEGER      NOT NULL REFERENCES dwh.dim_kpgz (kpgz_key),
    supplier_key          INTEGER      NOT NULL REFERENCES dwh.dim_supplier (supplier_key),

    -- атрибуты с малым числом значений — прямо в факте
    row_type              TEXT         NOT NULL CHECK (row_type IN ('competitive', 'direct', 'planned')),
    law                   SMALLINT     NOT NULL CHECK (law IN (44, 223)),
    procurement_level     TEXT,
    nmck_bucket           TEXT,

    -- меры (measures)
    nmck                  NUMERIC(18, 2),              -- аддитивная
    contract_price        NUMERIC(18, 2),              -- аддитивная
    savings               NUMERIC(18, 2),              -- аддитивная
    reduction_pct         NUMERIC(20, 4),              -- НЕаддитивная: только средние/медианы
    bids_submitted        INTEGER      CHECK (bids_submitted >= 0),
    bids_admitted         INTEGER      CHECK (bids_admitted >= 0),
    duration_days         INTEGER,
    n_rows                INTEGER      NOT NULL,
    n_contracts           INTEGER      NOT NULL,
    joint_size            INTEGER,

    -- флаги качества и признаки
    has_contract          BOOLEAN,
    is_per_unit           BOOLEAN      NOT NULL,
    is_joint              BOOLEAN      NOT NULL,
    is_reduction_valid    BOOLEAN      NOT NULL,
    is_date_invalid       BOOLEAN      NOT NULL,
    is_contract_conflict  BOOLEAN,
    is_nmck_missing       BOOLEAN      NOT NULL,
    no_bids               BOOLEAN,
    is_single_bid         BOOLEAN,
    is_single_admitted    BOOLEAN,

    -- происхождение (lineage)
    source_row_num        INTEGER      NOT NULL,

    CHECK (bids_admitted <= bids_submitted)
);

-- Индексы на внешние ключи: по ним идут JOIN и фильтры дашборда
CREATE INDEX ix_fact_lot_publish_date ON dwh.fact_lot (publish_date_key);
CREATE INDEX ix_fact_lot_method       ON dwh.fact_lot (method_key);
CREATE INDEX ix_fact_lot_grbs         ON dwh.fact_lot (grbs_key);
CREATE INDEX ix_fact_lot_customer     ON dwh.fact_lot (customer_key);
CREATE INDEX ix_fact_lot_kpgz         ON dwh.fact_lot (kpgz_key);
CREATE INDEX ix_fact_lot_supplier     ON dwh.fact_lot (supplier_key);
CREATE INDEX ix_fact_lot_row_type     ON dwh.fact_lot (row_type);

COMMENT ON TABLE  dwh.fact_lot IS 'Факт: один лот. Зерно — lot_id.';
COMMENT ON COLUMN dwh.fact_lot.reduction_pct IS
    'Конкурентные лоты: снижение на торгах. Прямые: min валидного снижения по лоту (неосвоенный лимит).';