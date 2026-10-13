"""Load: lots.parquet → stg.lots_clean → справочники и факт в dwh → сверка.

Python только доставляет очищенные данные в staging и запускает SQL.
Нормализация (справочники, суррогатные ключи, факт) выполняется SQL-скриптами.

Запуск из корня проекта:  python -m etl.load
"""
import csv
import io
import logging
import time

import pandas as pd

from etl.config import DATA_PROCESSED, ROOT, get_engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("load")

LOTS_PARQUET = DATA_PROCESSED / "lots.parquet"
SQL_DIR = ROOT / "sql"

# Скрипты построения хранилища — выполняются в ОДНОЙ транзакции
BUILD_SCRIPTS = [
    "01_dwh_schema.sql",   # пересоздать таблицы
    "02_dim_date.sql",     # календарь
    "03_load_dims.sql",    # справочники
    "04_load_fact.sql",    # факт
    "06_marts.sql",        # витрины (удаляются каскадно при пересоздании таблиц)
]
CHECKS_SCRIPT = "05_checks.sql"
TOTAL_STEPS = 3


def step(n, title):
    bar = "█" * n + "░" * (TOTAL_STEPS - n)
    log.info("[%s] шаг %d/%d: %s", bar, n, TOTAL_STEPS, title)


def copy_insert(table, conn, keys, data_iter):
    """Метод вставки для to_sql: COPY вместо INSERT (в десятки раз быстрее)."""
    buf = io.StringIO()
    csv.writer(buf).writerows(data_iter)
    buf.seek(0)
    columns = ", ".join(f'"{k}"' for k in keys)
    with conn.connection.cursor() as cur:
        cur.copy_expert(f"COPY {table.schema}.{table.name} ({columns}) FROM STDIN WITH CSV", buf)


def load_staging(engine):
    lots = pd.read_parquet(LOTS_PARQUET)
    lots.to_sql("lots_clean", engine, schema="stg", if_exists="replace",
                index=False, method=copy_insert)
    log.info("stg.lots_clean: %d строк", len(lots))


def build_warehouse(engine):
    """Все скрипты — одна транзакция: либо хранилище собрано целиком, либо не изменилось."""
    raw = engine.raw_connection()      # «сырое» соединение psycopg2: выполняет файл целиком
    try:
        with raw.cursor() as cur:
            for name in BUILD_SCRIPTS:
                t = time.perf_counter()
                cur.execute((SQL_DIR / name).read_text(encoding="utf-8"))
                log.info("  %-20s %.1f c", name, time.perf_counter() - t)
        raw.commit()
    except Exception:
        raw.rollback()
        log.error("Ошибка — транзакция откатена, хранилище не изменилось")
        raise
    finally:
        raw.close()


def run_checks(engine):
    checks = pd.read_sql((SQL_DIR / CHECKS_SCRIPT).read_text(encoding="utf-8"), engine)
    checks["passed"] = checks["expected"].fillna(0) == checks["actual"].fillna(0)
    for row in checks.itertuples():
        mark = "OK  " if row.passed else "FAIL"
        log.info("  %s %-36s %s", mark, row.check_name, f"{row.actual:,.0f}".replace(",", " "))
    if not checks["passed"].all():
        raise RuntimeError("Сверка не прошла — см. строки FAIL")


def main():
    engine = get_engine()
    started = time.perf_counter()

    step(1, "staging ← lots.parquet")
    load_staging(engine)

    step(2, "справочники и факт (SQL)")
    build_warehouse(engine)

    step(3, "сверка dwh со staging")
    run_checks(engine)

    log.info("Готово за %.0f c", time.perf_counter() - started)


if __name__ == "__main__":
    main()