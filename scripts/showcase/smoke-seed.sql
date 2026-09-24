-- Extra fixtures for scripts/smoke.sh, loaded after seed.sql. Kept apart so
-- the marketing screenshots don't show them.

CREATE SCHEMA smoke;

CREATE TABLE smoke.items (
    id     int PRIMARY KEY,
    name   text NOT NULL,
    price  numeric(10,2),
    note   text
);
INSERT INTO smoke.items
SELECT i, 'item ' || i, i * 1.5, NULL FROM generate_series(1, 30) i;

-- No primary key: edited through ctid.
CREATE TABLE smoke.nopk (label text, qty int);
INSERT INTO smoke.nopk VALUES ('alpha', 1), ('beta', 2), ('gamma', 3);

CREATE TABLE smoke.import_target (
    id      int PRIMARY KEY,
    name    text,
    note    text,
    amount  numeric(8,2)
);

-- NULL vs empty string, for the export checks.
CREATE TABLE smoke.export_probe (id int PRIMARY KEY, label text, n numeric);
INSERT INTO smoke.export_probe VALUES (1, NULL, 1.5), (2, '', 'NaN'), (3, 'a,"b"', NULL);
