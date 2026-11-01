-- Витрины для анализа и дашборда. Пересоздаются целиком: psql -f sql/10_marts.sql
\set ON_ERROR_STOP 1
DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;

-- 1. Заказ: одна строка на заказ, у которого есть позиции
CREATE TABLE mart.orders AS
WITH items AS (
  SELECT i.order_id,
         count(*)                         AS items_qty,
         count(DISTINCT i.seller_id)      AS sellers_qty,
         sum(i.price)                     AS gmv,
         sum(i.freight_value)             AS freight,
         -- основная категория заказа — категория самой дорогой позиции
         (array_agg(coalesce(t.product_category_name_english, p.product_category_name)
                    ORDER BY i.price DESC, i.order_item_id))[1] AS main_category
    FROM raw.order_items i
    JOIN raw.products p USING (product_id)
    LEFT JOIN raw.category_translation t USING (product_category_name)
   GROUP BY i.order_id
), pay AS (
  SELECT order_id,
         sum(payment_value)                                              AS paid,
         (array_agg(payment_type ORDER BY payment_value DESC))[1]        AS main_payment_type,
         max(payment_installments)                                       AS installments
    FROM raw.order_payments
   GROUP BY order_id
), rev AS (
  -- у 91 заказа несколько отзывов: берём последний
  SELECT DISTINCT ON (order_id) order_id, review_score
    FROM raw.order_reviews
   ORDER BY order_id, review_answer_timestamp DESC NULLS LAST, review_id
)
SELECT o.order_id,
       c.customer_unique_id,
       c.customer_state,
       o.order_status,
       o.order_purchase_timestamp                                    AS purchase_ts,
       date_trunc('month', o.order_purchase_timestamp)::date         AS purchase_month,
       it.items_qty, it.sellers_qty, it.gmv, it.freight, it.main_category,
       pay.paid, pay.main_payment_type, pay.installments,
       o.order_delivered_customer_date                               AS delivered_ts,
       o.order_estimated_delivery_date                               AS estimated_ts,
       round(extract(epoch FROM o.order_delivered_customer_date - o.order_purchase_timestamp) / 86400, 1) AS delivery_days,
       o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date                      AS delay_days,
       o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date                      AS is_late,
       rev.review_score,
       row_number() OVER w                                           AS customer_order_seq,
       lead(o.order_purchase_timestamp) OVER w                       AS next_purchase_ts
  FROM raw.orders o
  JOIN raw.customers c USING (customer_id)
  JOIN items it USING (order_id)
  LEFT JOIN pay USING (order_id)
  LEFT JOIN rev USING (order_id)
WINDOW w AS (PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp, o.order_id);

ALTER TABLE mart.orders ADD PRIMARY KEY (order_id);
CREATE INDEX ON mart.orders (customer_unique_id, purchase_ts);

-- Заказы, которые считаются покупкой: без отмен и недоступных
CREATE VIEW mart.valid_orders AS
SELECT * FROM mart.orders WHERE order_status NOT IN ('canceled', 'unavailable');

-- 2. Когорты по месяцу первой покупки: доля покупателей, вернувшихся через N месяцев
CREATE TABLE mart.cohort_retention AS
WITH firsts AS (
  SELECT customer_unique_id, min(purchase_month) AS cohort_month
    FROM mart.valid_orders GROUP BY 1
), activity AS (
  SELECT DISTINCT f.cohort_month, v.customer_unique_id,
         (extract(year FROM age(v.purchase_month, f.cohort_month)) * 12
          + extract(month FROM age(v.purchase_month, f.cohort_month)))::int AS month_offset
    FROM mart.valid_orders v JOIN firsts f USING (customer_unique_id)
)
SELECT cohort_month, month_offset,
       count(*)                                                        AS customers,
       first_value(count(*)) OVER (PARTITION BY cohort_month ORDER BY month_offset) AS cohort_size,
       round(100.0 * count(*) / first_value(count(*)) OVER (PARTITION BY cohort_month ORDER BY month_offset), 2) AS retention_pct
  FROM activity
 GROUP BY cohort_month, month_offset;

-- 3. Месячные показатели
CREATE TABLE mart.monthly_kpi AS
SELECT purchase_month,
       count(*)                                                        AS orders,
       count(DISTINCT customer_unique_id)                              AS customers,
       count(*) FILTER (WHERE customer_order_seq = 1)                  AS first_orders,
       round(sum(gmv), 2)                                              AS gmv,
       round(avg(gmv), 2)                                              AS aov,
       round(100.0 * avg(is_late::int) FILTER (WHERE delivered_ts IS NOT NULL), 2) AS late_pct,
       round(avg(review_score), 3)                                     AS avg_review,
       round(100.0 * avg((review_score <= 2)::int), 2)                 AS negative_review_pct
  FROM mart.valid_orders
 GROUP BY purchase_month;

-- 4. Категории: вклад в выручку (Парето), качество и логистика
CREATE TABLE mart.category_kpi AS
SELECT main_category,
       count(*)                                                        AS orders,
       round(sum(gmv), 2)                                              AS gmv,
       round(100.0 * sum(gmv) / sum(sum(gmv)) OVER (), 2)              AS gmv_share_pct,
       round(100.0 * sum(sum(gmv)) OVER (ORDER BY sum(gmv) DESC ROWS UNBOUNDED PRECEDING)
             / sum(sum(gmv)) OVER (), 2)                               AS gmv_cum_share_pct,
       round(avg(gmv), 2)                                              AS aov,
       round(100.0 * sum(freight) / nullif(sum(gmv), 0), 2)            AS freight_to_gmv_pct,
       round(avg(review_score), 3)                                     AS avg_review,
       round(100.0 * avg(is_late::int) FILTER (WHERE delivered_ts IS NOT NULL), 2) AS late_pct
  FROM mart.valid_orders
 GROUP BY main_category;

-- 5. Доставка по штатам покупателя
CREATE TABLE mart.delivery_by_state AS
SELECT customer_state,
       count(*)                                                        AS delivered_orders,
       round(avg(delivery_days), 1)                                    AS avg_delivery_days,
       round(avg(-delay_days), 1)                                      AS avg_days_before_estimate,
       round(100.0 * avg(is_late::int), 2)                             AS late_pct,
       round(avg(review_score), 3)                                     AS avg_review
  FROM mart.valid_orders
 WHERE delivered_ts IS NOT NULL
 GROUP BY customer_state;

-- 6. Опоздание и оценка: корзины по дням относительно обещанной даты
CREATE TABLE mart.delay_vs_review AS
SELECT CASE WHEN delay_days <= -15 THEN '01: раньше на 15+ дн'
            WHEN delay_days <= -8  THEN '02: раньше на 8–14 дн'
            WHEN delay_days <= -1  THEN '03: раньше на 1–7 дн'
            WHEN delay_days =  0   THEN '04: в обещанный день'
            WHEN delay_days <= 3   THEN '05: опоздание 1–3 дн'
            WHEN delay_days <= 7   THEN '06: опоздание 4–7 дн'
            WHEN delay_days <= 14  THEN '07: опоздание 8–14 дн'
            ELSE                        '08: опоздание 15+ дн' END    AS delay_bucket,
       count(*)                                                        AS orders,
       round(avg(review_score), 3)                                     AS avg_review,
       round(100.0 * avg((review_score <= 2)::int), 2)                 AS negative_review_pct
  FROM mart.valid_orders
 WHERE delivered_ts IS NOT NULL AND review_score IS NOT NULL
 GROUP BY 1;

-- 7. Воронка привлечения продавцов по каналу: квалифицированный лид → продавец с продажами
CREATE TABLE mart.seller_funnel AS
SELECT coalesce(nullif(q.origin, ''), 'unknown')                      AS origin,
       count(*)                                                        AS mql,
       count(c.mql_id)                                                 AS closed_active,
       round(100.0 * count(c.mql_id) / count(*), 2)                    AS conversion_pct,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY c.won_date::date - q.first_contact_date)
                                                                       AS median_days_to_close
  FROM raw.leads_qualified q
  LEFT JOIN raw.leads_closed c USING (mql_id)
 GROUP BY 1;

-- 8. RFM на дату последнего заказа в данных
CREATE TABLE mart.rfm AS
WITH c AS (
  SELECT customer_unique_id,
         (SELECT max(purchase_ts) FROM mart.valid_orders)::date - max(purchase_ts)::date AS recency_days,
         count(*)                                                      AS frequency,
         sum(gmv)                                                      AS monetary
    FROM mart.valid_orders GROUP BY 1
), s AS (
  SELECT *, ntile(4) OVER (ORDER BY recency_days DESC) AS r_score,   -- 4 — самые свежие
            ntile(4) OVER (ORDER BY monetary)          AS m_score    -- 4 — самые крупные
    FROM c
)
SELECT *,
       CASE WHEN frequency >= 2 AND r_score >= 3 THEN 'Постоянные'
            WHEN frequency >= 2                  THEN 'Повторные, давно не покупали'
            WHEN r_score >= 3 AND m_score >= 3   THEN 'Новые крупные'
            WHEN r_score >= 3                    THEN 'Новые'
            WHEN m_score >= 3                    THEN 'Ушедшие крупные'
            ELSE                                      'Ушедшие' END    AS segment
  FROM s;
