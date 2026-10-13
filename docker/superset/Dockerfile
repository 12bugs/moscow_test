FROM apache/superset:4.1.1

USER root
# Драйвер PostgreSQL: для подключения к хранилищу и для базы метаданных
RUN pip install --no-cache-dir psycopg2-binary==2.9.9
USER superset