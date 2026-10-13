"""Extract: Excel-источник → data/processed/raw.parquet + stg.raw_lots.

Смысл данных не меняется. Только технические преобразования:
имена колонок, типы для записи, метаданные происхождения.

Запуск из корня проекта:  python -m etl.extract
"""
import logging
from datetime import datetime, timezone

import pandas as pd

from etl.config import DATA_PROCESSED, DATA_RAW, get_engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("extract")

SOURCE_FILE = DATA_RAW / "Тестовое задание.xlsx"
RAW_PARQUET = DATA_PROCESSED / "raw.parquet"
STG_SCHEMA, STG_TABLE = "stg", "raw_lots"

# Контракт схемы: имя в источнике → техническое имя
COLUMN_MAP = {
    "Лот номер": "lot_id",
    "Закупка номер": "purchase_id",
    "Уровень осуществления закупки": "procurement_level",
    "Способ определения поставщика": "method",
    "Заказчик": "customer_id",
    "ГРБС": "grbs_id",
    "Комплекс": "complex",
    "Статус лота": "status",
    "НМЦК": "nmck",
    "Совместная закупка": "joint_purchase",
    "Цена за ед. продукции": "unit_price_flag",
    "КПГЗ 3": "kpgz_code",
    "КПГЗ 3 Наименование": "kpgz_name",
    "Дата публикации извещения": "publish_date",
    "Дата итогового протокола": "protocol_date",
    "Кол-во поданных заявок": "bids_submitted",
    "Кол-во допущенных участников": "bids_admitted",
    "Наименование победителя": "winner_name",
    "Снижение %": "reduction_pct",
    "Контракт": "has_contract",
    "Номер контракта": "contract_id",
    "ФЗ": "law",
    "Закупка на единицу продукции": "per_unit_flag",
}


def read_source() -> pd.DataFrame:
    log.info("Читаю %s", SOURCE_FILE.name)
    df = pd.read_excel(SOURCE_FILE)
    df.columns = df.columns.str.strip()
    log.info("Прочитано строк: %d, колонок: %d", *df.shape)
    return df


def validate_schema(df: pd.DataFrame) -> None:
    missing = set(COLUMN_MAP) - set(df.columns)
    extra = set(df.columns) - set(COLUMN_MAP)
    if missing or extra:
        raise ValueError(f"Схема источника изменилась. Нет: {missing}. Лишние: {extra}")
    log.info("Схема источника соответствует контракту")


def standardize(df: pd.DataFrame) -> pd.DataFrame:
    df = df.rename(columns=COLUMN_MAP)
    # колонка со смешанными значениями («Нет» и числа) — единый строковый тип
    df["joint_purchase"] = df["joint_purchase"].astype("string")
    return df


def add_metadata(df: pd.DataFrame) -> pd.DataFrame:
    df.insert(0, "source_row_num", range(2, len(df) + 2))   # строка 1 в Excel — заголовок
    df["source_file"] = SOURCE_FILE.name
    df["extracted_at"] = datetime.now(timezone.utc)
    return df


def save_parquet(df: pd.DataFrame) -> None:
    DATA_PROCESSED.mkdir(parents=True, exist_ok=True)
    df.to_parquet(RAW_PARQUET, index=False)
    log.info("Сохранено: %s", RAW_PARQUET.relative_to(DATA_PROCESSED.parent.parent))


def load_to_staging(df: pd.DataFrame) -> None:
    engine = get_engine()
    log.info("Загружаю в %s.%s", STG_SCHEMA, STG_TABLE)
    df.to_sql(
        STG_TABLE, engine, schema=STG_SCHEMA,
        if_exists="replace",      # полная перезагрузка → идемпотентность
        index=False, chunksize=10_000, method="multi",
    )


def reconcile(df: pd.DataFrame) -> None:
    from sqlalchemy import text
    with get_engine().connect() as conn:
        n_db = conn.execute(text(f"SELECT COUNT(*) FROM {STG_SCHEMA}.{STG_TABLE}")).scalar()
    if n_db != len(df):
        raise RuntimeError(f"Сверка не прошла: в DataFrame {len(df)}, в БД {n_db}")
    log.info("Сверка пройдена: %d строк", n_db)


def main() -> None:
    df = read_source()
    validate_schema(df)
    df = standardize(df)
    df = add_metadata(df)
    save_parquet(df)
    load_to_staging(df)
    reconcile(df)


if __name__ == "__main__":
    main()