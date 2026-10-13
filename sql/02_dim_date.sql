-- Календарь заполняется SQL-генератором, а не из данных:
-- в нём должны быть ВСЕ дни периода, даже те, в которые не было закупок.
TRUNCATE dwh.dim_date CASCADE;

INSERT INTO dwh.dim_date (date_key, full_date, year, quarter, month, month_name,
                          month_start, week_of_year, day_of_week, is_weekend)
SELECT TO_CHAR(d, 'YYYYMMDD')::INT,
       d::DATE,
       EXTRACT(YEAR    FROM d)::SMALLINT,
       EXTRACT(QUARTER FROM d)::SMALLINT,
       EXTRACT(MONTH   FROM d)::SMALLINT,
       (ARRAY['Январь','Февраль','Март','Апрель','Май','Июнь','Июль',
              'Август','Сентябрь','Октябрь','Ноябрь','Декабрь'])[EXTRACT(MONTH FROM d)],
       DATE_TRUNC('month', d)::DATE,
       EXTRACT(WEEK    FROM d)::SMALLINT,
       EXTRACT(ISODOW  FROM d)::SMALLINT,
       EXTRACT(ISODOW  FROM d) IN (6, 7)
FROM GENERATE_SERIES('2024-01-01'::DATE, '2026-12-31'::DATE, INTERVAL '1 day') AS d;

-- unknown member: для лотов без даты
INSERT INTO dwh.dim_date (date_key, month_name) VALUES (0, 'Не указана');