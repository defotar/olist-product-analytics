-- Выгрузка витрин для дашборда DataLens: русские заголовки, отфильтрованные периоды, поля для сортировки.
-- Запуск из корня проекта: psql -d olist -f sql/20_export.sql
\set ON_ERROR_STOP 1

-- Итоги за весь период: по одному числу на индикатор
\copy (SELECT (SELECT count(*) FROM mart.valid_orders) AS "Заказы", (SELECT round(sum(gmv)) FROM mart.valid_orders) AS "Выручка, BRL", (SELECT round(avg(gmv), 2) FROM mart.valid_orders) AS "Средний чек, BRL", (SELECT round(100.0 * avg(is_late::int), 2) FROM mart.valid_orders WHERE delivered_ts IS NOT NULL) AS "Опоздания, %", (SELECT round(100.0 * avg((frequency = 1)::int), 2) FROM mart.rfm) AS "Покупают один раз, %", (SELECT round(100.0 * sum(closed_active) / sum(mql), 2) FROM mart.seller_funnel) AS "Лид → продавец, %") TO 'marts/kpi_total.csv' WITH (FORMAT csv, HEADER)

-- Месяцы без неполных краёв: 2017-01 … 2018-08
\copy (SELECT purchase_month AS "Месяц", orders AS "Заказы", customers AS "Покупатели", first_orders AS "Новые покупатели", gmv AS "Выручка, BRL", aov AS "Средний чек, BRL", late_pct AS "Опоздания, %", avg_review AS "Средняя оценка", negative_review_pct AS "Плохие отзывы, %" FROM mart.monthly_kpi WHERE purchase_month BETWEEN '2017-01-01' AND '2018-08-01' ORDER BY 1) TO 'marts/monthly_kpi.csv' WITH (FORMAT csv, HEADER)

\copy (SELECT left(delay_bucket, 2)::int || '. ' || split_part(delay_bucket, ': ', 2) AS "Срок доставки", CASE WHEN delay_bucket LIKE '%опоздание%' THEN 'Опоздание' ELSE 'В срок' END AS "Опоздание", orders AS "Заказы", avg_review AS "Средняя оценка", negative_review_pct AS "Плохие отзывы, %" FROM mart.delay_vs_review ORDER BY 1) TO 'marts/delay_vs_review.csv' WITH (FORMAT csv, HEADER)

-- Когорты 2017-01 … 2018-03, месяцы 1–12
\copy (SELECT to_char(cohort_month, 'YYYY-MM') AS "Когорта", month_offset AS "Номер месяца", 'M' || lpad(month_offset::text, 2, '0') AS "Месяц после покупки", cohort_size AS "Размер когорты", customers AS "Вернулись", retention_pct AS "Вернулись, %" FROM mart.cohort_retention WHERE cohort_month BETWEEN '2017-01-01' AND '2018-03-01' AND month_offset BETWEEN 1 AND 12 ORDER BY 1, 2) TO 'marts/cohort_retention.csv' WITH (FORMAT csv, HEADER)

-- Штаты с заметным числом заказов
\copy (SELECT d.state_ru || ' (' || customer_state || ')' AS "Штат", delivered_orders AS "Доставлено заказов", avg_delivery_days AS "Срок доставки, дн", avg_days_before_estimate AS "Раньше обещанного, дн", late_pct AS "Опоздания, %", avg_review AS "Средняя оценка" FROM mart.delivery_by_state JOIN mart.dict_state_ru d ON d.state = customer_state WHERE delivered_orders > 500 ORDER BY late_pct DESC) TO 'marts/delivery_by_state.csv' WITH (FORMAT csv, HEADER)

\copy (SELECT d.channel_ru AS "Канал", mql AS "Лиды", closed_active AS "Стали продавцами", conversion_pct AS "Конверсия, %", median_days_to_close AS "Дней до сделки (медиана)" FROM mart.seller_funnel JOIN mart.dict_channel_ru d USING (origin) WHERE mql >= 100 ORDER BY conversion_pct DESC) TO 'marts/seller_funnel.csv' WITH (FORMAT csv, HEADER)

\copy (SELECT coalesce(d.category_ru, main_category) AS "Категория", orders AS "Заказы", gmv AS "Выручка, BRL", gmv_share_pct AS "Доля выручки, %", gmv_cum_share_pct AS "Накопленная доля, %", avg_review AS "Средняя оценка", late_pct AS "Опоздания, %" FROM mart.category_kpi LEFT JOIN mart.dict_category_ru d ON d.category = main_category ORDER BY gmv DESC) TO 'marts/category_kpi.csv' WITH (FORMAT csv, HEADER)

\copy (SELECT segment AS "Сегмент", count(*) AS "Покупатели", round(sum(monetary)) AS "Выручка, BRL", round(avg(recency_days)) AS "Дней с последней покупки", round(avg(frequency), 2) AS "Заказов на покупателя" FROM mart.rfm GROUP BY 1 ORDER BY 2 DESC) TO 'marts/rfm_segments.csv' WITH (FORMAT csv, HEADER)
