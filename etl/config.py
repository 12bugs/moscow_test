"""Общие настройки ETL: пути к файлам и подключение к БД."""
import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine, URL

ROOT = Path(__file__).resolve().parents[1]      # корень проекта
load_dotenv(ROOT / ".env")                      # читаем пароли из .env

DATA_RAW = ROOT / "data" / "raw"
DATA_PROCESSED = ROOT / "data" / "processed"


def get_engine():
    url = URL.create(
        "postgresql+psycopg2",
        username=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        host=os.environ["POSTGRES_HOST"],
        port=int(os.environ["POSTGRES_PORT"]),
        database=os.environ["POSTGRES_DB"],
    )
    return create_engine(url)