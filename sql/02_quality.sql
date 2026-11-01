-- Проверки качества данных: каждая строка — проверка, число нарушений и комментарий
\pset footer off
WITH pay AS (SELECT order_id, sum(payment_value) AS paid FROM raw.order_payments GROUP BY order_id),
     itm AS (SELECT order_id, sum(price + freight_value) AS due FROM raw.order_items GROUP BY order_id),
     rev AS (SELECT order_id, count(*) AS n FROM raw.order_reviews GROUP BY order_id)
SELECT * FROM (VALUES
  ('Период заказов',
     (SELECT min(order_purchase_timestamp)::date || ' — ' || max(order_purchase_timestamp)::date FROM raw.orders)),
  ('Заказы по статусам',
     (SELECT string_agg(order_status || ': ' || n, ', ' ORDER BY n DESC)
        FROM (SELECT order_status, count(*) n FROM raw.orders GROUP BY 1) s)),
  ('Доставленные без даты вручения',
     (SELECT count(*)::text FROM raw.orders WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL)),
  ('Вручение раньше покупки',
     (SELECT count(*)::text FROM raw.orders WHERE order_delivered_customer_date < order_purchase_timestamp)),
  ('Заказы без позиций',
     (SELECT count(*)::text FROM raw.orders o WHERE NOT EXISTS (SELECT 1 FROM raw.order_items i WHERE i.order_id = o.order_id))),
  ('Заказы без оплаты',
     (SELECT count(*)::text FROM raw.orders o WHERE NOT EXISTS (SELECT 1 FROM pay WHERE pay.order_id = o.order_id))),
  ('Оплата расходится с суммой позиций больше чем на 1',
     (SELECT count(*)::text FROM pay JOIN itm USING (order_id) WHERE abs(paid - due) > 1)),
  ('Заказы с несколькими отзывами',
     (SELECT count(*)::text FROM rev WHERE n > 1)),
  ('Доставленные заказы без отзыва',
     (SELECT count(*)::text FROM raw.orders o WHERE order_status = 'delivered'
        AND NOT EXISTS (SELECT 1 FROM raw.order_reviews r WHERE r.order_id = o.order_id))),
  ('Товары без категории',
     (SELECT count(*)::text FROM raw.products WHERE product_category_name IS NULL)),
  ('Категории без перевода',
     (SELECT count(DISTINCT p.product_category_name)::text FROM raw.products p
        LEFT JOIN raw.category_translation t USING (product_category_name)
       WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL)),
  ('Позиции с товаром не из справочника',
     (SELECT count(*)::text FROM raw.order_items i WHERE NOT EXISTS (SELECT 1 FROM raw.products p WHERE p.product_id = i.product_id))),
  ('Покупателей (customer_unique_id) / заказов',
     (SELECT count(DISTINCT customer_unique_id) || ' / ' || count(*) FROM raw.customers)),
  ('Закрытые сделки, продавца нет в Sellers',
     (SELECT count(*)::text FROM raw.leads_closed c WHERE NOT EXISTS (SELECT 1 FROM raw.sellers s WHERE s.seller_id = c.seller_id)))
) AS q(check_name, result);
