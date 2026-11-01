-- Загрузка CSV из data/raw (запускать psql из корня проекта: см. run.sh)
\set ON_ERROR_STOP 1
\copy raw.customers            FROM 'data/raw/customers.csv'                         WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.sellers              FROM 'data/raw/Sellers.csv'                           WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.products             FROM 'data/raw/Products.csv'                          WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.category_translation FROM 'data/raw/Product_category_name_translation.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.orders               FROM 'data/raw/Orders.csv'                            WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.order_items          FROM 'data/raw/Order_items.csv'                       WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.order_payments       FROM 'data/raw/Order_payments.csv'                    WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.order_reviews        FROM 'data/raw/Order_reviews.csv'                     WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.geolocation          FROM 'data/raw/geolocation.csv'                       WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.leads_qualified      FROM 'data/raw/leads_qualified.csv'                   WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
\copy raw.leads_closed         FROM 'data/raw/leads_closed.csv'                      WITH (FORMAT csv, DELIMITER E'\t', HEADER, NULL 'NULL')
ANALYZE;
