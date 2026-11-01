#!/bin/zsh
# Полный прогон: загрузка CSV → витрины → проверки → анализ → выгрузка витрин для DataLens.
# Нужны: PostgreSQL (по умолчанию Postgres.app), python3; данные в data/raw (см. data/README.md).
set -e
cd "$(dirname "$0")"
PSQL=("${PGBIN:-/Applications/Postgres.app/Contents/Versions/latest/bin}/psql" -h "${PGHOST:-localhost}" -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'olist'" | grep -q 1 \
  || "${PSQL[@]}" -d postgres -c "CREATE DATABASE olist"
"${PSQL[@]}" -d olist -f sql/00_schema.sql -f sql/01_load.sql -f sql/10_marts.sql -f sql/15_dicts_ru.sql 2>&1 | grep -v NOTICE || true
"${PSQL[@]}" -d olist -f sql/02_quality.sql | tee reports/quality.txt
[ -d .venv ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
.venv/bin/python analysis/analyze.py > /dev/null
"${PSQL[@]}" -d olist -f sql/20_export.sql
echo "Готово: reports/results.json, reports/figures, marts/*.csv"
