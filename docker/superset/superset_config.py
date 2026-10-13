"""Конфигурация Superset. Значения берутся из .env (передаётся в контейнер через env_file)."""
import os

# Секретный ключ: шифрует сессии и пароли подключений. Сгенерировать: openssl rand -base64 42
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# Метаданные Superset (пользователи, датасеты, графики, дашборды) — в отдельной базе
# того же Postgres. Хост — ИМЯ СЕРВИСА в docker-compose, порт — внутренний 5432.
SQLALCHEMY_DATABASE_URI = (
    "postgresql+psycopg2://"
    f"{os.environ['POSTGRES_USER']}:{os.environ['POSTGRES_PASSWORD']}"
    f"@{os.environ.get('SUPERSET_DB_HOST', 'postgres')}:5432/"
    f"{os.environ.get('SUPERSET_META_DB', 'superset')}"
)

# Русский интерфейс (перевод частичный; переключатель языка — в правом верхнем углу)
BABEL_DEFAULT_LOCALE = "ru"
LANGUAGES = {"ru": {"flag": "ru", "name": "Русский"}, "en": {"flag": "us", "name": "English"}}

# Нативные фильтры дашборда и перекрёстная фильтрация кликом по графику
FEATURE_FLAGS = {
    "DASHBOARD_NATIVE_FILTERS": True,
    "DASHBOARD_CROSS_FILTERS": True,
}

ROW_LIMIT = 50_000
SQLLAB_TIMEOUT = 300