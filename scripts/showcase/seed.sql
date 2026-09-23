-- Showcase dataset for scripts/screenshots.sh: a fictional online store
-- ("Driftwood Supply Co.") with billing, analytics and inventory schemas.
-- Every name, company and address is generated; nothing refers to a real
-- person or business. Deterministic: setseed() fixes random().

\set ON_ERROR_STOP on
SET client_min_messages = warning;
DO $$ BEGIN PERFORM setseed(0.42); END $$;

CREATE SCHEMA billing;
CREATE SCHEMA analytics;
CREATE SCHEMA inventory;

COMMENT ON SCHEMA public    IS 'Storefront: customers, catalogue and orders';
COMMENT ON SCHEMA billing   IS 'Plans, subscriptions, invoices and payments';
COMMENT ON SCHEMA analytics IS 'Product events and reporting rollups';
COMMENT ON SCHEMA inventory IS 'Warehouses and stock levels';

CREATE TYPE order_status   AS ENUM ('pending', 'paid', 'packed', 'shipped', 'delivered', 'refunded', 'cancelled');
CREATE TYPE product_status AS ENUM ('draft', 'active', 'discontinued');
CREATE TYPE billing.invoice_status AS ENUM ('draft', 'open', 'paid', 'void', 'uncollectible');

-- ---------------------------------------------------------------- helpers
CREATE TEMP TABLE first_names(i int, v text);
INSERT INTO first_names SELECT row_number() OVER (), v FROM unnest(ARRAY[
  'Ava','Liam','Mila','Noah','Isla','Elias','Freya','Mateo','Nora','Oskar','Lena','Hugo','Ines','Arlo',
  'Maja','Theo','Clara','Felix','Zoe','Jonas','Aria','Leo','Elsa','Milan','Rosa','Anton','Iris','Emil',
  'Luna','Rafael','Vera','Silas','Alma','Nico','Ida','Kai','Hanna','Levi','Stella','Otto','June','Tomas',
  'Nadia','Bruno','Selma','Ezra','Livia','Axel','Mira','Casper'
]) AS v;
CREATE TEMP TABLE last_names(i int, v text);
INSERT INTO last_names SELECT row_number() OVER (), v FROM unnest(ARRAY[
  'Lindqvist','Moreau','Novak','Brandt','Castell','Okafor','Varga','Halden','Rossi','Kowal','Ferreira',
  'Aalto','Dunmore','Sato','Petrov','Quinlan','Bergström','Marchetti','Hollis','Vance','Kaya','Duarte',
  'Ellery','Strand','Nakamura','Oyelaran','Falk','Renard','Achterberg','Whitlow','Solberg','Ibarra',
  'Castellan','Morrow','Dragan','Holm','Lacroix','Voss','Mendel','Arden'
]) AS v;
CREATE TEMP TABLE companies(i int, v text);
INSERT INTO companies SELECT row_number() OVER (), v FROM unnest(ARRAY[
  'Bluefern Studio','Kestrel Logistics','Oakridge Analytics','Lumen & Vale','Harborlight Media',
  'Copperleaf Labs','Northgale Outfitters','Tidewater Design','Brightmoss Co.','Ironbark Systems',
  'Saltmarsh Coffee','Juniper Row','Quillfeather Books','Stonebridge Dental','Wildcress Foods'
]) AS v;
CREATE TEMP TABLE cities(i int, city text, country text);
INSERT INTO cities SELECT row_number() OVER (), c, k FROM (VALUES
  ('Berlin','DE'),('Prague','CZ'),('Amsterdam','NL'),('Lisbon','PT'),('Copenhagen','DK'),('Vienna','AT'),
  ('Barcelona','ES'),('Stockholm','SE'),('Dublin','IE'),('Paris','FR'),('Milan','IT'),('Warsaw','PL'),
  ('Oslo','NO'),('Helsinki','FI'),('Zurich','CH'),('Brussels','BE'),('London','GB'),('Edinburgh','GB'),
  ('New York','US'),('Portland','US'),('Austin','US'),('Toronto','CA'),('Melbourne','AU'),('Tokyo','JP')
) AS t(c, k);

-- ---------------------------------------------------------------- public
CREATE TABLE categories (
    id          serial PRIMARY KEY,
    parent_id   int REFERENCES categories(id),
    name        text NOT NULL UNIQUE,
    slug        text NOT NULL UNIQUE
);
COMMENT ON TABLE categories IS 'Catalogue tree; parent_id NULL for top-level departments';

INSERT INTO categories (name, slug) VALUES
  ('Kitchen','kitchen'),('Outdoor','outdoor'),('Workshop','workshop'),('Home Office','home-office'),('Textiles','textiles');
INSERT INTO categories (parent_id, name, slug) VALUES
  (1,'Cookware','cookware'),(1,'Knives','knives'),(1,'Coffee & Tea','coffee-tea'),
  (2,'Camping','camping'),(2,'Garden Tools','garden-tools'),
  (3,'Hand Tools','hand-tools'),(3,'Storage','storage'),
  (4,'Desks','desks'),(4,'Lighting','lighting'),
  (5,'Blankets','blankets'),(5,'Linen','linen');

CREATE TABLE products (
    id            bigserial PRIMARY KEY,
    public_id     uuid NOT NULL UNIQUE,
    sku           text NOT NULL UNIQUE,
    name          text NOT NULL,
    category_id   int NOT NULL REFERENCES categories(id),
    status        product_status NOT NULL DEFAULT 'draft',
    price         numeric(10,2) NOT NULL CHECK (price >= 0),
    list_price    money,
    tags          text[] NOT NULL DEFAULT '{}',
    attributes    jsonb NOT NULL DEFAULT '{}',
    warranty      interval,
    is_featured   boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE products IS 'Sellable items; attributes holds per-category specs';
COMMENT ON COLUMN products.list_price IS 'Manufacturer''s suggested retail price';
COMMENT ON COLUMN products.warranty IS 'Warranty period offered at checkout';

WITH adjectives(i, a) AS (SELECT row_number() OVER (), a FROM unnest(ARRAY[
  'Cast Iron','Walnut','Linen','Copper','Oak','Canvas','Enamel','Stoneware','Ash','Brass','Wool','Steel'
]) a),
nouns(i, n, cat) AS (SELECT row_number() OVER (), n, c FROM (VALUES
  ('Skillet',6),('Dutch Oven',6),('Chef Knife',7),('Paring Knife',7),('Pour-Over Kettle',8),('Tea Tin',8),
  ('Camp Stool',9),('Lantern',9),('Trowel',10),('Pruning Shears',10),('Block Plane',11),('Chisel Set',11),
  ('Tool Roll',12),('Crate',12),('Standing Desk',13),('Monitor Riser',13),('Desk Lamp',14),('Pendant Light',14),
  ('Throw Blanket',15),('Picnic Blanket',15),('Tea Towel',16),('Apron',16)
) t(n, c))
INSERT INTO products (public_id, sku, name, category_id, status, price, list_price, tags, attributes,
                      warranty, is_featured, created_at, updated_at)
SELECT md5('product' || g)::uuid,
       'DW-' || lpad((1000 + g)::text, 5, '0'),
       a.a || ' ' || n.n,
       n.cat,
       (CASE WHEN g % 17 = 0 THEN 'discontinued' WHEN g % 11 = 0 THEN 'draft' ELSE 'active' END)::product_status,
       round((12 + random() * 380)::numeric, 2) AS price,
       NULL,
       string_to_array((ARRAY['bestseller,gift','new','eco,handmade','sale','handmade','','limited,gift'])[1 + g % 7], ','),
       jsonb_build_object(
           'material', lower(a.a),
           'weight_g', (150 + (random() * 4800)::int),
           'dimensions', jsonb_build_object('w', 10 + g % 40, 'h', 5 + g % 25, 'd', 3 + g % 15),
           'origin', (ARRAY['PT','CZ','DK','JP','SE','IT'])[1 + g % 6]),
       (ARRAY['1 year','2 years','6 mons','5 years','90 days'])[1 + g % 5]::interval,
       g % 9 = 0,
       timestamptz '2025-03-01 09:00+00' + (g * interval '31 hours'),
       timestamptz '2026-08-01 09:00+00' + (g * interval '3 hours')
FROM generate_series(1, 240) g
JOIN adjectives a ON a.i = 1 + (g * 7) % 12
JOIN nouns n ON n.i = 1 + g % 22;
UPDATE products SET list_price = (price * 1.25)::numeric::money;

CREATE TABLE customers (
    id              bigserial PRIMARY KEY,
    public_id       uuid NOT NULL UNIQUE,
    first_name      text NOT NULL,
    last_name       text NOT NULL,
    email           text NOT NULL UNIQUE,
    company         text,
    city            text,
    country         char(2) NOT NULL,
    is_vip          boolean NOT NULL DEFAULT false,
    lifetime_value  numeric(12,2) NOT NULL DEFAULT 0,
    tags            text[] NOT NULL DEFAULT '{}',
    preferences     jsonb NOT NULL DEFAULT '{}',
    last_login_ip   inet,
    signed_up_at    timestamptz NOT NULL
);
COMMENT ON TABLE customers IS 'Storefront accounts';
COMMENT ON COLUMN customers.lifetime_value IS 'Sum of paid orders, refreshed nightly';

INSERT INTO customers (public_id, first_name, last_name, email, company, city, country, is_vip,
                       tags, preferences, last_login_ip, signed_up_at)
SELECT md5('customer' || g)::uuid, f.v, l.v,
       lower(translate(f.v || '.' || l.v, 'öäåéü', 'oaaeu')) || g || '@' ||
           (ARRAY['example.com','example.org','example.net'])[1 + g % 3],
       CASE WHEN g % 4 = 0 THEN c.v END,
       ci.city, ci.country,
       g % 23 = 0,
       string_to_array((ARRAY['newsletter','','wholesale,net-30','newsletter,early-access'])[1 + g % 4], ','),
       jsonb_build_object('currency', (ARRAY['EUR','EUR','USD','GBP','CZK'])[1 + g % 5],
                          'marketing', g % 3 <> 0, 'theme', (ARRAY['light','dark','auto'])[1 + g % 3]),
       ('10.' || (g % 200) || '.' || (g * 7 % 250) || '.' || (1 + g % 250))::inet,
       timestamptz '2024-01-05 10:00+00' + g * interval '15 hours 13 minutes'
FROM generate_series(1, 1200) g
JOIN first_names f ON f.i = 1 + (g * 13) % 50
JOIN last_names l ON l.i = 1 + (g * 7) % 40
JOIN companies c ON c.i = 1 + g % 15
JOIN cities ci ON ci.i = 1 + (g * 5) % 24;

CREATE TABLE orders (
    id                bigint NOT NULL,
    order_number      text NOT NULL,
    customer_id       bigint NOT NULL REFERENCES customers(id),
    status            order_status NOT NULL DEFAULT 'pending',
    placed_at         timestamptz NOT NULL,
    items             int NOT NULL,
    subtotal          numeric(12,2) NOT NULL,
    shipping          numeric(8,2) NOT NULL DEFAULT 0,
    total             numeric(12,2) NOT NULL,
    currency          char(3) NOT NULL DEFAULT 'EUR',
    channel           text NOT NULL,
    ship_to_country   char(2) NOT NULL,
    client_ip         inet,
    gift_note         text,
    PRIMARY KEY (id, placed_at)
) PARTITION BY RANGE (placed_at);
COMMENT ON TABLE orders IS 'Checkout orders, partitioned by month';
COMMENT ON COLUMN orders.channel IS 'web, ios, android or pos';

DO $$
DECLARE m date;
BEGIN
  FOR m IN SELECT generate_series(date '2026-01-01', date '2026-09-01', interval '1 month')::date LOOP
    EXECUTE format('CREATE TABLE %I PARTITION OF orders FOR VALUES FROM (%L) TO (%L)',
                   'orders_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month')::date);
  END LOOP;
END $$;

INSERT INTO orders (id, order_number, customer_id, status, placed_at, items, subtotal, shipping, total,
                    currency, channel, ship_to_country, client_ip, gift_note)
SELECT g,
       'SO-' || (104000 + g),
       1 + ((g * 7919) % 1200),
       (CASE
          WHEN g > 5850 THEN (ARRAY['pending','paid','packed'])[1 + g % 3]
          WHEN g % 41 = 0 THEN 'refunded'
          WHEN g % 53 = 0 THEN 'cancelled'
          WHEN g > 5600 THEN 'shipped'
          ELSE 'delivered' END)::order_status,
       timestamptz '2026-01-01 06:00+00' + (g * interval '63 minutes') + ((g % 37) * interval '17 seconds'),
       0, 0, (ARRAY[0, 4.90, 9.90, 0, 14.50])[1 + g % 5], 0,
       (ARRAY['EUR','EUR','EUR','USD','GBP'])[1 + g % 5],
       (ARRAY['web','web','ios','android','web','pos'])[1 + g % 6],
       (ARRAY['DE','CZ','NL','PT','DK','AT','ES','SE','IE','FR','IT','US','GB'])[1 + g % 13],
       ('192.0.2.' || (1 + g % 250))::inet,
       CASE WHEN g % 29 = 0 THEN (ARRAY['Happy birthday, Mira!','For the new kitchen','Congrats on the move',
                                        'Thanks for everything','Merry midsummer'])[1 + g % 5] END
FROM generate_series(1, 6000) g;

CREATE TABLE order_items (
    order_id     bigint NOT NULL,
    placed_at    timestamptz NOT NULL,
    line_no      smallint NOT NULL,
    product_id   bigint NOT NULL REFERENCES products(id),
    quantity     int NOT NULL CHECK (quantity > 0),
    unit_price   numeric(10,2) NOT NULL,
    discount     numeric(4,3) NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id, placed_at, line_no),
    FOREIGN KEY (order_id, placed_at) REFERENCES orders(id, placed_at) ON DELETE CASCADE
);
COMMENT ON TABLE order_items IS 'Order lines; the composite FK follows the partitioned orders key';

INSERT INTO order_items (order_id, placed_at, line_no, product_id, quantity, unit_price, discount)
SELECT o.id, o.placed_at, l, p.id, 1 + ((o.id + l) % 4 = 0)::int + ((o.id * l) % 7 = 0)::int, p.price,
       CASE WHEN (o.id + l) % 9 = 0 THEN 0.100 WHEN (o.id + l) % 25 = 0 THEN 0.250 ELSE 0 END
FROM orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.id % 4)::int) l
JOIN products p ON p.id = 1 + ((o.id * 31 + l * 17) % 240);

UPDATE orders o SET items = s.n, subtotal = s.sub, total = s.sub + o.shipping
FROM (SELECT order_id, placed_at, sum(quantity)::int n,
             round(sum(quantity * unit_price * (1 - discount)), 2) sub
      FROM order_items GROUP BY 1, 2) s
WHERE s.order_id = o.id AND s.placed_at = o.placed_at;

UPDATE customers c SET lifetime_value = s.v
FROM (SELECT customer_id, sum(total) v FROM orders WHERE status IN ('paid','packed','shipped','delivered')
      GROUP BY 1) s
WHERE s.customer_id = c.id;

CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_status_idx ON orders (status) WHERE status IN ('pending', 'paid', 'packed');
CREATE INDEX products_tags_idx ON products USING gin (tags);
CREATE INDEX products_attributes_idx ON products USING gin (attributes jsonb_path_ops);
CREATE INDEX customers_country_city_idx ON customers (country, city);
CREATE INDEX order_items_product_idx ON order_items (product_id);

CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER products_touch BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE FUNCTION customer_display_name(c customers) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT c.first_name || ' ' || c.last_name || coalesce(' (' || c.company || ')', '')
$$;

CREATE VIEW order_summaries AS
SELECT o.order_number, o.placed_at, o.status, c.first_name || ' ' || c.last_name AS customer,
       c.country, o.items, o.total, o.currency, o.channel
FROM orders o JOIN customers c ON c.id = o.customer_id;
COMMENT ON VIEW order_summaries IS 'Orders with the customer name, for support';

-- ---------------------------------------------------------------- billing
CREATE TABLE billing.plans (
    code          text PRIMARY KEY,
    name          text NOT NULL,
    monthly_fee   money NOT NULL,
    seats         int,
    features      jsonb NOT NULL DEFAULT '[]'
);
INSERT INTO billing.plans VALUES
  ('starter','Starter', 9, 1, '["catalogue","email support"]'),
  ('team','Team', 49, 10, '["catalogue","wholesale pricing","priority support"]'),
  ('business','Business', 199, 50, '["catalogue","wholesale pricing","net-30 terms","account manager"]');
COMMENT ON TABLE billing.plans IS 'Wholesale membership plans';

CREATE TABLE billing.subscriptions (
    id               bigserial PRIMARY KEY,
    customer_id      bigint NOT NULL REFERENCES public.customers(id),
    plan_code        text NOT NULL REFERENCES billing.plans(code),
    started_at       timestamptz NOT NULL,
    billing_period   interval NOT NULL DEFAULT '1 mon',
    trial_ends_at    timestamptz,
    cancelled_at     timestamptz,
    auto_renew       boolean NOT NULL DEFAULT true
);
INSERT INTO billing.subscriptions (customer_id, plan_code, started_at, billing_period, trial_ends_at, cancelled_at, auto_renew)
SELECT 4 * g, (ARRAY['starter','team','team','business'])[1 + g % 4],
       timestamptz '2025-02-01 00:00+00' + g * interval '19 hours',
       CASE WHEN g % 5 = 0 THEN interval '1 year' ELSE interval '1 mon' END,
       timestamptz '2025-02-15 00:00+00' + g * interval '19 hours',
       CASE WHEN g % 13 = 0 THEN timestamptz '2026-05-01 00:00+00' + g * interval '2 hours' END,
       g % 13 <> 0
FROM generate_series(1, 300) g;

CREATE TABLE billing.invoices (
    id              bigserial PRIMARY KEY,
    number          text NOT NULL UNIQUE,
    subscription_id bigint NOT NULL REFERENCES billing.subscriptions(id),
    status          billing.invoice_status NOT NULL,
    issued_on       date NOT NULL,
    due_on          date NOT NULL,
    amount          numeric(12,2) NOT NULL,
    tax_rate        numeric(5,4) NOT NULL DEFAULT 0.21,
    line_items      jsonb NOT NULL
);
COMMENT ON TABLE billing.invoices IS 'Membership invoices; line_items mirrors the PDF';
INSERT INTO billing.invoices (number, subscription_id, status, issued_on, due_on, amount, tax_rate, line_items)
SELECT 'INV-2026-' || lpad(g::text, 5, '0'), 1 + g % 300,
       (CASE WHEN g > 1900 THEN 'open' WHEN g % 31 = 0 THEN 'void' WHEN g % 67 = 0 THEN 'uncollectible' ELSE 'paid' END)::billing.invoice_status,
       date '2026-01-01' + (g / 8), date '2026-01-15' + (g / 8),
       (ARRAY[9, 49, 49, 199])[1 + (1 + g % 300) % 4],
       (ARRAY[0.21, 0.19, 0.20, 0.25])[1 + g % 4],
       jsonb_build_array(jsonb_build_object('description', 'Membership', 'qty', 1,
                         'amount', (ARRAY[9, 49, 49, 199])[1 + (1 + g % 300) % 4]))
FROM generate_series(1, 2000) g;

CREATE TABLE billing.payments (
    id            bigserial PRIMARY KEY,
    invoice_id    bigint NOT NULL REFERENCES billing.invoices(id),
    paid_at       timestamptz NOT NULL,
    amount        numeric(12,2) NOT NULL,
    method        text NOT NULL,
    reference     uuid NOT NULL
);
INSERT INTO billing.payments (invoice_id, paid_at, amount, method, reference)
SELECT i.id, i.issued_on + interval '2 days 3 hours', round(i.amount * (1 + i.tax_rate), 2),
       (ARRAY['card','card','sepa','invoice'])[1 + i.id % 4], md5('pay' || i.id)::uuid
FROM billing.invoices i WHERE i.status = 'paid';

CREATE FUNCTION billing.invoice_total(invoice_id bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT round(amount * (1 + tax_rate), 2) FROM billing.invoices WHERE id = invoice_id
$$;
COMMENT ON FUNCTION billing.invoice_total(bigint) IS 'Gross amount including tax';

CREATE VIEW billing.mrr_by_plan AS
SELECT p.name AS plan, count(*) AS active_subscriptions, sum(p.monthly_fee) AS mrr
FROM billing.subscriptions s JOIN billing.plans p ON p.code = s.plan_code
WHERE s.cancelled_at IS NULL
GROUP BY p.name;

-- ---------------------------------------------------------------- analytics
CREATE TABLE analytics.events (
    id           bigserial PRIMARY KEY,
    occurred_at  timestamptz NOT NULL,
    session_id   uuid NOT NULL,
    customer_id  bigint REFERENCES public.customers(id),
    event_type   text NOT NULL,
    path         text,
    properties   jsonb NOT NULL DEFAULT '{}',
    duration     interval
);
COMMENT ON TABLE analytics.events IS 'Clickstream from the storefront';
INSERT INTO analytics.events (occurred_at, session_id, customer_id, event_type, path, properties, duration)
SELECT timestamptz '2026-08-01 00:00+00' + g * interval '7 minutes 41 seconds',
       md5('session' || (g / 6))::uuid,
       CASE WHEN g % 5 <> 0 THEN 1 + (g * 37) % 1200 END,
       (ARRAY['page_view','page_view','search','add_to_cart','page_view','checkout_started','purchase'])[1 + g % 7],
       (ARRAY['/','/c/kitchen','/p/cast-iron-skillet','/search','/cart','/checkout','/c/outdoor'])[1 + g % 7],
       jsonb_build_object('device', (ARRAY['desktop','mobile','tablet'])[1 + g % 3],
                          'referrer', (ARRAY['direct','newsletter','search','social'])[1 + g % 4]),
       make_interval(secs => 2 + (g * 13) % 240)
FROM generate_series(1, 8000) g;
CREATE INDEX events_occurred_idx ON analytics.events USING brin (occurred_at);
CREATE INDEX events_type_idx ON analytics.events (event_type, occurred_at);

CREATE MATERIALIZED VIEW analytics.daily_revenue AS
SELECT date_trunc('day', placed_at)::date AS day, count(*) AS orders, sum(total) AS revenue,
       round(avg(total), 2) AS avg_order_value
FROM public.orders WHERE status NOT IN ('cancelled', 'refunded')
GROUP BY 1;
CREATE UNIQUE INDEX daily_revenue_day_idx ON analytics.daily_revenue (day);
COMMENT ON MATERIALIZED VIEW analytics.daily_revenue IS 'Refreshed hourly by refresh_rollups()';

CREATE VIEW analytics.funnel AS
SELECT event_type, count(*) AS events, count(DISTINCT session_id) AS sessions
FROM analytics.events GROUP BY event_type;

CREATE FUNCTION analytics.refresh_rollups() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.daily_revenue;
END $$;

-- ---------------------------------------------------------------- inventory
CREATE TABLE inventory.warehouses (
    id        serial PRIMARY KEY,
    code      text NOT NULL UNIQUE,
    city      text NOT NULL,
    country   char(2) NOT NULL,
    opened_on date NOT NULL
);
INSERT INTO inventory.warehouses (code, city, country, opened_on) VALUES
  ('PRG-1','Prague','CZ','2021-04-12'),('RTM-1','Rotterdam','NL','2022-09-01'),
  ('LIS-1','Lisbon','PT','2023-03-20'),('PDX-1','Portland','US','2024-06-03');

CREATE TABLE inventory.stock_levels (
    warehouse_id  int NOT NULL REFERENCES inventory.warehouses(id),
    product_id    bigint NOT NULL REFERENCES public.products(id),
    on_hand       int NOT NULL,
    reserved      int NOT NULL DEFAULT 0,
    reorder_at    int NOT NULL DEFAULT 20,
    PRIMARY KEY (warehouse_id, product_id)
);
INSERT INTO inventory.stock_levels
SELECT w.id, p.id, (p.id * 37 + w.id * 11) % 180, (p.id + w.id) % 12, 20
FROM inventory.warehouses w CROSS JOIN public.products p;

CREATE TABLE inventory.stock_movements (
    id            bigserial PRIMARY KEY,
    warehouse_id  int NOT NULL,
    product_id    bigint NOT NULL,
    moved_at      timestamptz NOT NULL,
    delta         int NOT NULL,
    reason        text NOT NULL,
    FOREIGN KEY (warehouse_id, product_id) REFERENCES inventory.stock_levels(warehouse_id, product_id)
);
COMMENT ON TABLE inventory.stock_movements IS 'Append-only ledger; composite FK to stock_levels';
INSERT INTO inventory.stock_movements (warehouse_id, product_id, moved_at, delta, reason)
SELECT 1 + g % 4, 1 + (g * 13) % 240, timestamptz '2026-06-01 08:00+00' + g * interval '23 minutes',
       CASE WHEN g % 6 = 0 THEN 24 ELSE -1 - g % 3 END,
       CASE WHEN g % 6 = 0 THEN 'restock' WHEN g % 50 = 0 THEN 'damaged' ELSE 'order' END
FROM generate_series(1, 3000) g;

CREATE VIEW inventory.low_stock AS
SELECT w.code AS warehouse, p.sku, p.name, s.on_hand - s.reserved AS available, s.reorder_at
FROM inventory.stock_levels s
JOIN inventory.warehouses w ON w.id = s.warehouse_id
JOIN public.products p ON p.id = s.product_id
WHERE s.on_hand - s.reserved < s.reorder_at;

-- ---------------------------------------------------------------- PostGIS (optional)
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS postgis;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'PostGIS not available, skipping stores';
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN RETURN; END IF;
  EXECUTE $sql$
    CREATE TABLE public.stores (
        id         serial PRIMARY KEY,
        name       text NOT NULL,
        city       text NOT NULL,
        country    char(2) NOT NULL,
        opened_on  date NOT NULL,
        sqm        int NOT NULL,
        location   geometry(Point, 4326) NOT NULL
    )
  $sql$;
  EXECUTE $sql$COMMENT ON TABLE public.stores IS 'Driftwood Supply Co. retail locations'$sql$;
  EXECUTE $sql$
    INSERT INTO public.stores (name, city, country, opened_on, sqm, location)
    SELECT 'Driftwood ' || city, city, country, date '2019-03-01' + (row_number() OVER () * 97)::int,
           180 + (row_number() OVER () * 37 % 420)::int, ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    FROM (VALUES
      ('Berlin','DE',13.4050,52.5200),('Prague','CZ',14.4378,50.0755),('Amsterdam','NL',4.9041,52.3676),
      ('Lisbon','PT',-9.1393,38.7223),('Copenhagen','DK',12.5683,55.6761),('Vienna','AT',16.3738,48.2082),
      ('Barcelona','ES',2.1734,41.3851),('Stockholm','SE',18.0686,59.3293),('Dublin','IE',-6.2603,53.3498),
      ('Paris','FR',2.3522,48.8566),('Milan','IT',9.1900,45.4642),('Warsaw','PL',21.0122,52.2297),
      ('Oslo','NO',10.7522,59.9139),('Helsinki','FI',24.9384,60.1699),('Zurich','CH',8.5417,47.3769),
      ('Brussels','BE',4.3517,50.8503),('London','GB',-0.1276,51.5072),('Edinburgh','GB',-3.1883,55.9533),
      ('Munich','DE',11.5820,48.1351),('Hamburg','DE',9.9937,53.5511),('Porto','PT',-8.6291,41.1579),
      ('Madrid','ES',-3.7038,40.4168),('Rome','IT',12.4964,41.9028),('Budapest','HU',19.0402,47.4979)
    ) AS t(city, country, lon, lat)
  $sql$;
  EXECUTE $sql$CREATE INDEX stores_location_idx ON public.stores USING gist (location)$sql$;
END $$;

ANALYZE;
