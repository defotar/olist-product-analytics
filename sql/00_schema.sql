-- Схема raw: таблицы один в один с CSV, типы проставлены при загрузке
DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.customers (
  customer_id              TEXT PRIMARY KEY,
  customer_unique_id       TEXT NOT NULL,
  customer_zip_code_prefix INT,
  customer_city            TEXT,
  customer_state           CHAR(2)
);

CREATE TABLE raw.sellers (
  seller_id              TEXT PRIMARY KEY,
  seller_zip_code_prefix INT,
  seller_city            TEXT,
  seller_state           CHAR(2)
);

CREATE TABLE raw.products (
  product_id                 TEXT PRIMARY KEY,
  product_category_name      TEXT,
  product_name_lenght        INT,
  product_description_lenght INT,
  product_photos_qty         INT,
  product_weight_g           INT,
  product_length_cm          INT,
  product_height_cm          INT,
  product_width_cm           INT
);

CREATE TABLE raw.category_translation (
  product_category_name         TEXT PRIMARY KEY,
  product_category_name_english TEXT NOT NULL
);

CREATE TABLE raw.orders (
  order_id                      TEXT PRIMARY KEY,
  customer_id                   TEXT NOT NULL REFERENCES raw.customers,
  order_status                  TEXT NOT NULL,
  order_purchase_timestamp      TIMESTAMP NOT NULL,
  order_approved_at             TIMESTAMP,
  order_delivered_carrier_date  TIMESTAMP,
  order_delivered_customer_date TIMESTAMP,
  order_estimated_delivery_date TIMESTAMP
);

CREATE TABLE raw.order_items (
  order_id            TEXT NOT NULL REFERENCES raw.orders,
  order_item_id       INT NOT NULL,
  product_id          TEXT NOT NULL,
  seller_id           TEXT NOT NULL,
  shipping_limit_date TIMESTAMP,
  price               NUMERIC(10, 2) NOT NULL,
  freight_value       NUMERIC(10, 2) NOT NULL,
  PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE raw.order_payments (
  order_id             TEXT NOT NULL REFERENCES raw.orders,
  payment_sequential   INT NOT NULL,
  payment_type         TEXT NOT NULL,
  payment_installments INT,
  payment_value        NUMERIC(10, 2) NOT NULL,
  PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE raw.order_reviews (
  review_id               TEXT NOT NULL,
  order_id                TEXT NOT NULL REFERENCES raw.orders,
  review_score            SMALLINT NOT NULL CHECK (review_score BETWEEN 1 AND 5),
  review_comment_title    TEXT,
  review_comment_message  TEXT,
  review_creation_date    TIMESTAMP,
  review_answer_timestamp TIMESTAMP
);

CREATE TABLE raw.geolocation (
  geolocation_id              INT PRIMARY KEY,
  geolocation_zip_code_prefix INT,
  geolocation_lat             DOUBLE PRECISION,
  geolocation_lng             DOUBLE PRECISION,
  geolocation_city            TEXT,
  geolocation_state           CHAR(2)
);

-- Воронка привлечения продавцов: квалифицированные лиды и закрытые сделки
CREATE TABLE raw.leads_qualified (
  mql_id             TEXT PRIMARY KEY,
  first_contact_date DATE NOT NULL,
  landing_page_id    TEXT,
  origin             TEXT
);

CREATE TABLE raw.leads_closed (
  mql_id                        TEXT PRIMARY KEY REFERENCES raw.leads_qualified,
  seller_id                     TEXT,
  sdr_id                        TEXT,
  sr_id                         TEXT,
  won_date                      TIMESTAMP,
  business_segment              TEXT,
  lead_type                     TEXT,
  lead_behaviour_profile        TEXT,
  has_company                   BOOLEAN,
  has_gtin                      BOOLEAN,
  average_stock                 TEXT,
  business_type                 TEXT,
  declared_product_catalog_size NUMERIC,
  declared_monthly_revenue      NUMERIC
);
