"""Transform: data/processed/raw.parquet → lots.parquet + quality_log.csv.

Каждое правило очистки из EDA — отдельная функция. Каждая функция
записывает в журнал качества, сколько строк она затронула.

Запуск из корня проекта:  python -m etl.transform
"""
import logging

import numpy as np
import pandas as pd

from etl.config import DATA_PROCESSED

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("transform")

RAW_PARQUET = DATA_PROCESSED / "raw.parquet"
LOTS_PARQUET = DATA_PROCESSED / "lots.parquet"
QUALITY_LOG = DATA_PROCESSED / "quality_log.csv"

METADATA_COLS = ["source_row_num", "source_file", "extracted_at"]
SINGLE_SUPPLIER = "Закупка у единственного поставщика"

METHOD_GROUPS = {
    "Электронный аукцион": "Аукцион",
    "Открытый аукцион": "Аукцион",
    "Закрытый аукцион": "Закрытая процедура",
    "Закрытый электронный аукцион": "Закрытая процедура",
    "Электронный конкурс": "Конкурс",
    "Открытый конкурс": "Конкурс",
    "Закрытый конкурс": "Закрытая процедура",
    "Закрытый электронный конкурс": "Закрытая процедура",
    "Электронный запрос котировок": "Запрос котировок",
    "Котировочная сессия": "Запрос котировок",
    "Электронный запрос предложений": "Запрос предложений",
    SINGLE_SUPPLIER: "Единственный поставщик",
}

# Порядок важен: длинные формы раньше коротких (ПАО раньше АО)
LEGAL_FORMS = [
    ("ОБЩЕСТВО С ОГРАНИЧЕННОЙ ОТВЕТСТВЕННОСТЬЮ", "ООО"),
    ("ПУБЛИЧНОЕ АКЦИОНЕРНОЕ ОБЩЕСТВО", "ПАО"),
    ("НЕПУБЛИЧНОЕ АКЦИОНЕРНОЕ ОБЩЕСТВО", "АО"),
    ("ЗАКРЫТОЕ АКЦИОНЕРНОЕ ОБЩЕСТВО", "ЗАО"),
    ("ОТКРЫТОЕ АКЦИОНЕРНОЕ ОБЩЕСТВО", "ОАО"),
    ("АКЦИОНЕРНОЕ ОБЩЕСТВО", "АО"),
    ("ИНДИВИДУАЛЬНЫЙ ПРЕДПРИНИМАТЕЛЬ", "ИП"),
    ("ФЕДЕРАЛЬНОЕ ГОСУДАРСТВЕННОЕ УНИТАРНОЕ ПРЕДПРИЯТИЕ", "ФГУП"),
    ("ГОСУДАРСТВЕННОЕ УНИТАРНОЕ ПРЕДПРИЯТИЕ", "ГУП"),
    ("ГОСУДАРСТВЕННОЕ БЮДЖЕТНОЕ УЧРЕЖДЕНИЕ", "ГБУ"),
    ("ГОСУДАРСТВЕННОЕ АВТОНОМНОЕ УЧРЕЖДЕНИЕ", "ГАУ"),
    ("ГОСУДАРСТВЕННОЕ КАЗЕННОЕ УЧРЕЖДЕНИЕ", "ГКУ"),
]


class QualityLog:
    """Журнал качества: какое правило сколько строк затронуло."""

    def __init__(self):
        self.records = []

    def add(self, rule_no, rule, rows_affected, action):
        self.records.append(
            {"rule_no": rule_no, "rule": rule, "rows_affected": int(rows_affected), "action": action}
        )
        log.info("[%s] %s: %d", rule_no, rule, rows_affected)

    def to_frame(self):
        return pd.DataFrame(self.records)


# ---------- правила уровня строк ----------

def drop_full_duplicates(df, qlog):
    # метаданные уникальны для каждой строки, поэтому дубли ищем без них
    data_cols = [c for c in df.columns if c not in METADATA_COLS]
    dup = df.duplicated(subset=data_cols)
    qlog.add(1, "Полные дубли строк", dup.sum(), "удалены")
    return df[~dup].copy()


def cast_types(df, qlog):
    for col in ["publish_date", "protocol_date"]:
        raw = df[col]
        df[col] = pd.to_datetime(raw, format="%d.%m.%Y", errors="coerce")
        bad = raw.notna() & df[col].isna()
        qlog.add(14, f"Неразборчивая дата: {col}", bad.sum(), "значение → NULL")
    for col in ["purchase_id", "contract_id", "bids_submitted", "bids_admitted"]:
        df[col] = df[col].astype("Int64")
    df["has_contract"] = df["has_contract"].map({"Да": True, "Нет": False}).astype("boolean")
    return df


def per_unit_flag(df, qlog):
    same = (df["unit_price_flag"] == df["per_unit_flag"]).all()
    if not same:
        raise ValueError("Колонки «на единицу продукции» перестали совпадать — пересмотрите правило 2")
    df["is_per_unit"] = df["per_unit_flag"].astype(bool)
    qlog.add(2, "Закупки на единицу продукции", df["is_per_unit"].sum(), "дубль-колонка удалена, флаг is_per_unit")
    return df.drop(columns=["unit_price_flag", "per_unit_flag"])


def reduction_validity(df, qlog):
    df["is_reduction_valid"] = df["reduction_pct"].between(0, 100)
    bad = df["reduction_pct"].notna() & ~df["is_reduction_valid"]
    qlog.add(3, "Снижение вне 0–100", bad.sum(), "флаг is_reduction_valid = False")
    return df


def date_validity(df, qlog):
    df["is_date_invalid"] = df["protocol_date"] < df["publish_date"]
    df["duration_days"] = (df["protocol_date"] - df["publish_date"]).dt.days.astype("Int64")
    df.loc[df["is_date_invalid"], "duration_days"] = pd.NA
    qlog.add(4, "Протокол раньше публикации", df["is_date_invalid"].sum(), "duration_days = NULL")
    return df


def contract_conflict(df, qlog):
    df["is_contract_conflict"] = (df["has_contract"] == False) & df["contract_id"].notna()  # noqa: E712
    qlog.add(5, "Контракт = Нет, номер заполнен", df["is_contract_conflict"].sum(), "флаг, значение не меняем")
    return df


def normalize_winner(df, qlog):
    s = df["winner_name"].str.upper().str.replace("Ё", "Е", regex=False)
    for full, short in LEGAL_FORMS:
        s = s.str.replace(full, short, regex=False)
    s = (s.str.replace(r"[«»\"'“”„]", "", regex=True)
          .str.replace(r"\s+", " ", regex=True)
          .str.strip())
    before, after = df["winner_name"].nunique(), s.nunique()
    df["winner_name_norm"] = s
    qlog.add(6, f"Нормализация победителей: {before} → {after}", before - after, "названия объединены")
    return df


def classify_rows(df, qlog):
    competitive = df["bids_submitted"].notna()
    direct = ~competitive & (df["method"] == SINGLE_SUPPLIER)
    df["row_type"] = np.select([competitive, direct], ["competitive", "direct"], default="planned")
    for t, n in df["row_type"].value_counts().items():
        qlog.add(7, f"Тип строки: {t}", n, "row_type")
    return df


def zero_bids(df, qlog):
    df["no_bids"] = df["bids_submitted"] == 0
    fix = df["no_bids"] & df["bids_admitted"].isna()
    df.loc[fix, "bids_admitted"] = 0
    qlog.add(10, "0 заявок, допущенные пусты", fix.sum(), "bids_admitted = 0, флаг no_bids")
    return df


def nmck_missing(df, qlog):
    df["is_nmck_missing"] = df["nmck"].isna() | (df["nmck"] <= 0)
    qlog.add(11, "НМЦК пустая или ≤ 0", df["is_nmck_missing"].sum(), "исключается из денежных метрик")
    return df


def method_group(df, qlog):
    df["method_group"] = df["method"].map(METHOD_GROUPS)
    unknown = df["method_group"].isna()
    if unknown.any():
        raise ValueError(f"Новые способы закупки: {df.loc[unknown, 'method'].unique()}")
    qlog.add(12, "Группировка способов", df["method"].nunique(), f"→ {df['method_group'].nunique()} групп")
    return df


def joint_purchase(df, qlog):
    s = df["joint_purchase"].str.strip()
    df["is_joint"] = (s != "Нет").astype(bool)
    df["joint_size"] = pd.to_numeric(s.where(df["is_joint"]), errors="coerce").astype("Int64")
    qlog.add(13, "Совместная закупка", df["is_joint"].sum(), "is_joint + joint_size")
    return df.drop(columns=["joint_purchase"])


def fill_unknown(df, qlog):
    for rule_no, col, label in [(15, "complex", "Пустой комплекс"), (16, "status", "Пустой статус")]:
        miss = df[col].isna()
        df[col] = df[col].fillna("Не указан")
        qlog.add(rule_no, label, miss.sum(), "«Не указан»")
    return df


# ---------- переход к зерну «лот» ----------

def build_lots(df, qlog):
    """Одна строка на лот (правила 8 и 9)."""
    type_rank = df["row_type"].map({"competitive": 0, "direct": 1, "planned": 2})
    ranked = (df.assign(_type_rank=type_rank, _has_contract_id=df["contract_id"].notna())
                .sort_values(["lot_id", "_type_rank", "_has_contract_id", "protocol_date", "source_row_num"],
                             ascending=[True, True, False, False, False]))

    # агрегаты по всем строкам лота
    valid_red = df["reduction_pct"].where(df["is_reduction_valid"])
    agg = (df.assign(_valid_red=valid_red)
             .groupby("lot_id")
             .agg(n_rows=("lot_id", "size"),
                  n_competitive_rows=("row_type", lambda t: (t == "competitive").sum()),
                  n_contracts=("contract_id", "nunique"),
                  min_valid_reduction=("_valid_red", "min")))

    # представительная строка: конкурентная → с номером контракта → самая поздняя
    lots = (ranked.drop_duplicates("lot_id", keep="first")
                  .drop(columns=["_type_rank", "_has_contract_id"])
                  .set_index("lot_id")
                  .join(agg)
                  .reset_index())

    multi_comp = (lots["row_type"] == "competitive") & (lots["n_competitive_rows"] > 1)
    qlog.add(8, "Многострочные конкурентные лоты", multi_comp.sum(), "одна представительная строка на лот")

    # правило 9: для прямых закупок — минимальное ВАЛИДНОЕ снижение по лоту
    direct = lots["row_type"] == "direct"
    lots.loc[direct, "reduction_pct"] = lots.loc[direct, "min_valid_reduction"]
    lots.loc[direct, "is_reduction_valid"] = lots.loc[direct, "reduction_pct"].notna()
    multi_direct = direct & (lots["n_rows"] > 1)
    qlog.add(9, "Многострочные лоты ед. поставщика", multi_direct.sum(), "снижение = min валидного по лоту")
    qlog.add(9, "…из них без валидного снижения", (multi_direct & lots["reduction_pct"].isna()).sum(), "снижение → NULL")

    return lots.drop(columns=["min_valid_reduction", "n_competitive_rows"])


def add_lot_metrics(lots):
    comp = lots["row_type"] == "competitive"
    money_ok = comp & lots["is_reduction_valid"] & ~lots["is_nmck_missing"] & ~lots["is_per_unit"]
    lots["contract_price"] = np.where(money_ok, lots["nmck"] * (1 - lots["reduction_pct"] / 100), np.nan)
    lots["savings"] = np.where(money_ok, lots["nmck"] - lots["contract_price"], np.nan)
    lots["is_single_bid"] = comp & (lots["bids_submitted"] == 1)
    lots["is_single_admitted"] = comp & (lots["bids_admitted"] == 1)
    lots["publish_month"] = lots["publish_date"].dt.to_period("M").dt.to_timestamp()
    lots["nmck_bucket"] = pd.cut(
        lots["nmck"], bins=[0, 1e6, 1e7, 1e8, np.inf],
        labels=["до 1 млн", "1–10 млн", "10–100 млн", "свыше 100 млн"], include_lowest=True,
    ).astype("string")
    return lots


def main():
    qlog = QualityLog()
    df = pd.read_parquet(RAW_PARQUET)
    log.info("Прочитано строк: %d", len(df))

    for step in [drop_full_duplicates, cast_types, per_unit_flag, reduction_validity,
                 date_validity, contract_conflict, normalize_winner, classify_rows,
                 zero_bids, nmck_missing, method_group, joint_purchase, fill_unknown]:
        df = step(df, qlog)

    lots = add_lot_metrics(build_lots(df, qlog))

    lots.to_parquet(LOTS_PARQUET, index=False)
    qlog.to_frame().to_csv(QUALITY_LOG, index=False)
    log.info("Лотов: %d → %s", len(lots), LOTS_PARQUET.name)
    log.info("Журнал качества → %s", QUALITY_LOG.name)


if __name__ == "__main__":
    main()