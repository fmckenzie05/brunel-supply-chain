-- Brunel Supply Chain: cleanup layer
-- Run AFTER load_brunel.sql (or load_data_only.sql), in psql connected to supply_chain:
--   \i 'C:/Users/ferna/OneDrive/Documents/Postgres/Brunel_Supply_Chain/clean_brunel.sql'
--
-- Raw tables in schema "brunel" are left untouched. Cleaned tables go to schema "clean".
-- Safe to re-run: it drops and rebuilds the clean schema each time.
--
-- Fixes applied:
--   1. freight_rates: trim padded mode values ("AIR   " -> "AIR")
--   2. freight_rates: drop exact duplicate rows
--   3. freight_rates: collapse conflicting rates for the same lane/band/service/mode
--      to one row (lowest rate, then lowest minimum cost)
--   4. order_list: move zero-weight orders to clean.order_exceptions
--   5. order_list: add flags for CRF orders (no carrier rate by design),
--      zero transit days, and unit-quantity outliers (IQR rule)

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA clean;

-- Dimension tables: already clean, copied as-is --------------------------------

CREATE TABLE clean.wh_costs           AS SELECT * FROM brunel.wh_costs;
CREATE TABLE clean.wh_capacities      AS SELECT * FROM brunel.wh_capacities;
CREATE TABLE clean.plant_ports        AS SELECT * FROM brunel.plant_ports;
CREATE TABLE clean.products_per_plant AS SELECT * FROM brunel.products_per_plant;
CREATE TABLE clean.vmi_customers      AS SELECT * FROM brunel.vmi_customers;

ALTER TABLE clean.wh_costs           ADD PRIMARY KEY (plant_code);
ALTER TABLE clean.wh_capacities      ADD PRIMARY KEY (plant_code);
ALTER TABLE clean.plant_ports        ADD PRIMARY KEY (plant_code, port);
ALTER TABLE clean.products_per_plant ADD PRIMARY KEY (plant_code, product_id);
ALTER TABLE clean.vmi_customers      ADD PRIMARY KEY (plant_code, customer);

-- Freight rates: trim, dedupe, one rate per lane/band/service/mode -------------

CREATE TABLE clean.freight_rates AS
SELECT DISTINCT ON (carrier, orig_port, dest_port, min_weight, max_weight,
                    service_level, trim(mode))
       rate_id,
       carrier,
       orig_port,
       dest_port,
       min_weight,
       max_weight,
       service_level,
       minimum_cost,
       rate,
       trim(mode)   AS mode,
       transit_days,
       carrier_type
FROM brunel.freight_rates
ORDER BY carrier, orig_port, dest_port, min_weight, max_weight,
         service_level, trim(mode),
         rate, minimum_cost, rate_id;          -- cheapest row wins

ALTER TABLE clean.freight_rates ADD PRIMARY KEY (rate_id);
ALTER TABLE clean.freight_rates
    ADD CONSTRAINT freight_rates_lane_uq
    UNIQUE (carrier, orig_port, dest_port, min_weight, max_weight, service_level, mode);

-- Orders: pull out bad records -------------------------------------------------

CREATE TABLE clean.order_exceptions AS
SELECT o.*, 'zero weight'::text AS reason
FROM brunel.order_list o
WHERE o.weight = 0;

-- Orders: clean table with analysis flags --------------------------------------

CREATE TABLE clean.order_list AS
WITH qty_bounds AS (
    SELECT percentile_cont(0.75) WITHIN GROUP (ORDER BY unit_quantity)
         + 1.5 * ( percentile_cont(0.75) WITHIN GROUP (ORDER BY unit_quantity)
                 - percentile_cont(0.25) WITHIN GROUP (ORDER BY unit_quantity) )
           AS upper_fence
    FROM brunel.order_list
    WHERE weight > 0
)
SELECT o.*,
       (o.service_level = 'CRF')          AS is_crf,           -- customer arranges freight; no rate expected
       (o.transit_days = 0)               AS is_zero_transit,
       (o.unit_quantity > q.upper_fence)  AS is_qty_outlier
FROM brunel.order_list o
CROSS JOIN qty_bounds q
WHERE o.weight > 0;

ALTER TABLE clean.order_list ADD PRIMARY KEY (order_id);
ALTER TABLE clean.order_list
    ADD CONSTRAINT order_list_plant_fk FOREIGN KEY (plant_code)
    REFERENCES clean.wh_costs (plant_code);

CREATE INDEX ON clean.order_list (carrier);
CREATE INDEX ON clean.order_list (customer);
CREATE INDEX ON clean.order_list (plant_code);
CREATE INDEX ON clean.freight_rates (carrier, orig_port, dest_port, service_level, mode);

COMMIT;

ANALYZE clean.order_list;
ANALYZE clean.freight_rates;

-- Validation -------------------------------------------------------------------

\echo '--- Row counts: raw vs clean'
SELECT 'order_list' AS table_name,
       (SELECT count(*) FROM brunel.order_list)    AS raw_rows,
       (SELECT count(*) FROM clean.order_list)     AS clean_rows
UNION ALL
SELECT 'freight_rates',
       (SELECT count(*) FROM brunel.freight_rates),
       (SELECT count(*) FROM clean.freight_rates)
UNION ALL
SELECT 'order_exceptions', NULL,
       (SELECT count(*) FROM clean.order_exceptions);

\echo '--- Order flags'
SELECT count(*) FILTER (WHERE is_crf)          AS crf_orders,
       count(*) FILTER (WHERE is_zero_transit) AS zero_transit_orders,
       count(*) FILTER (WHERE is_qty_outlier)  AS qty_outlier_orders
FROM clean.order_list;

\echo '--- Checks (all should be 0)'
SELECT
    (SELECT count(*) FROM clean.freight_rates WHERE mode <> trim(mode))   AS padded_modes,
    (SELECT count(*) FROM clean.order_list WHERE weight = 0)              AS zero_weight_orders,
    (SELECT count(*) FROM clean.order_list o
       WHERE NOT o.is_crf
         AND NOT EXISTS (SELECT 1 FROM clean.freight_rates r
                         WHERE r.carrier = o.carrier))                    AS non_crf_orders_without_carrier_rate;
