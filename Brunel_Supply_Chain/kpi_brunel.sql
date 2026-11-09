-- Brunel Supply Chain: KPI views
-- Run AFTER clean_brunel.sql, in psql connected to supply_chain:
--   \i 'C:/Users/ferna/OneDrive/Documents/Postgres/Brunel_Supply_Chain/kpi_brunel.sql'
--
-- Builds schema "kpi" with views (Tableau / Excel can connect to these directly):
--   kpi.order_costs       one row per order with freight + warehouse cost
--   kpi.summary           headline KPIs, one row
--   kpi.by_carrier        cost, on-time and transit by carrier / service level
--   kpi.by_plant          warehouse cost and capacity utilization by plant
--   kpi.by_service_level  mix and on-time by service level
--   kpi.top_customers     customer concentration
--
-- Freight cost rule (from the Brunel problem definition):
--   cost = greatest(minimum_cost, rate * weight), matched on carrier, origin port,
--   destination port, service level and weight band.
--   CRF orders = 0 freight cost (customer arranges and pays).
--   Orders with no matching rate band = NULL (source rate table has a gap for
--   V444_1 / PORT04 / DTD between 2.51 and 70.50 kg).

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS kpi CASCADE;
CREATE SCHEMA kpi;

-- Base view: every order with its costs ----------------------------------------

CREATE VIEW kpi.order_costs AS
SELECT o.order_id,
       o.order_date,
       o.plant_code,
       o.origin_port,
       o.dest_port,
       o.carrier,
       o.service_level,
       o.customer,
       o.product_id,
       o.unit_quantity,
       o.weight,
       o.transit_days,
       o.ship_ahead_days,
       o.ship_late_days,
       (o.ship_late_days = 0)                       AS is_on_time,
       (o.ship_ahead_days > 0)                      AS is_shipped_early,
       o.is_crf,
       o.is_qty_outlier,
       r.mode,
       CASE WHEN o.is_crf THEN 0
            ELSE round(greatest(r.minimum_cost, r.rate * o.weight), 2)
       END                                          AS freight_cost,
       round(o.unit_quantity * w.cost_per_unit, 2)  AS warehouse_cost
FROM clean.order_list o
JOIN clean.wh_costs w
  ON w.plant_code = o.plant_code
LEFT JOIN clean.freight_rates r
  ON  r.carrier       = o.carrier
  AND r.orig_port     = o.origin_port
  AND r.dest_port     = o.dest_port
  AND r.service_level = o.service_level
  AND o.weight BETWEEN r.min_weight AND r.max_weight
  AND NOT o.is_crf;

-- Headline KPIs ----------------------------------------------------------------

CREATE VIEW kpi.summary AS
SELECT count(*)                                                    AS total_orders,
       sum(unit_quantity)                                          AS total_units,
       round(sum(weight), 0)                                       AS total_weight,
       count(DISTINCT customer)                                    AS customers,
       count(DISTINCT product_id)                                  AS products,
       round(100.0 * avg(is_on_time::int), 2)                      AS on_time_pct,
       round(100.0 * avg(is_shipped_early::int), 2)                AS shipped_early_pct,
       round(avg(ship_late_days) FILTER (WHERE NOT is_on_time), 2) AS avg_days_late_when_late,
       round(avg(transit_days), 2)                                 AS avg_transit_days,
       round(100.0 * avg((freight_cost IS NOT NULL)::int), 2)      AS freight_costed_pct,
       sum(freight_cost)                                           AS total_freight_cost,
       round(sum(freight_cost) / nullif(sum(weight)
             FILTER (WHERE freight_cost > 0), 0), 4)               AS freight_cost_per_weight,
       sum(warehouse_cost)                                         AS total_warehouse_cost,
       round(sum(warehouse_cost) / sum(unit_quantity), 4)          AS warehouse_cost_per_unit,
       round(100.0 * avg(is_crf::int), 2)                          AS crf_pct
FROM kpi.order_costs;

-- By carrier and service level ---------------------------------------------------

CREATE VIEW kpi.by_carrier AS
SELECT carrier,
       service_level,
       count(*)                                                   AS orders,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)         AS order_share_pct,
       sum(unit_quantity)                                         AS units,
       round(sum(weight), 0)                                      AS weight,
       round(100.0 * avg(is_on_time::int), 2)                     AS on_time_pct,
       round(avg(transit_days), 2)                                AS avg_transit_days,
       count(freight_cost)                                        AS costed_orders,
       sum(freight_cost)                                          AS freight_cost,
       round(avg(freight_cost), 2)                                AS freight_cost_per_order,
       round(sum(freight_cost) / nullif(sum(weight)
             FILTER (WHERE freight_cost IS NOT NULL), 0), 4)      AS freight_cost_per_weight
FROM kpi.order_costs
GROUP BY carrier, service_level;

-- By plant: warehouse cost and capacity utilization --------------------------------
-- Dataset is a single day of orders, so orders / daily_capacity = utilization.

CREATE VIEW kpi.by_plant AS
SELECT w.plant_code,
       coalesce(count(c.order_id), 0)                              AS orders,
       c2.daily_capacity,
       round(100.0 * count(c.order_id) / c2.daily_capacity, 1)     AS capacity_utilization_pct,
       (count(c.order_id) > c2.daily_capacity)                     AS over_capacity,
       coalesce(sum(c.unit_quantity), 0)                           AS units,
       round(w.cost_per_unit, 4)                                   AS cost_per_unit,
       coalesce(sum(c.warehouse_cost), 0)                          AS warehouse_cost,
       round(100.0 * coalesce(sum(c.warehouse_cost), 0)
             / sum(sum(c.warehouse_cost)) OVER (), 2)              AS warehouse_cost_share_pct
FROM clean.wh_costs w
JOIN clean.wh_capacities c2 ON c2.plant_code = w.plant_code
LEFT JOIN kpi.order_costs c ON c.plant_code = w.plant_code
GROUP BY w.plant_code, c2.daily_capacity, w.cost_per_unit;

-- By service level ---------------------------------------------------------------

CREATE VIEW kpi.by_service_level AS
SELECT service_level,
       count(*)                                            AS orders,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)  AS order_share_pct,
       round(100.0 * avg(is_on_time::int), 2)              AS on_time_pct,
       round(100.0 * avg(is_shipped_early::int), 2)        AS shipped_early_pct,
       round(avg(transit_days), 2)                         AS avg_transit_days
FROM kpi.order_costs
GROUP BY service_level;

-- Customer concentration -----------------------------------------------------------

CREATE VIEW kpi.top_customers AS
SELECT customer,
       count(*)                                                       AS orders,
       sum(unit_quantity)                                             AS units,
       round(100.0 * sum(unit_quantity) / sum(sum(unit_quantity)) OVER (), 2)
                                                                      AS unit_share_pct,
       round(100.0 * sum(sum(unit_quantity)) OVER (ORDER BY sum(unit_quantity) DESC)
             / sum(sum(unit_quantity)) OVER (), 2)                    AS cumulative_unit_share_pct,
       round(100.0 * avg(is_on_time::int), 2)                         AS on_time_pct
FROM kpi.order_costs
GROUP BY customer;

COMMIT;

-- Results ------------------------------------------------------------------------

\x on
\echo '=== Headline KPIs'
SELECT * FROM kpi.summary;
\x off

\echo '=== By carrier / service level'
SELECT * FROM kpi.by_carrier ORDER BY orders DESC;

\echo '=== Plants with orders (capacity + warehouse cost)'
SELECT * FROM kpi.by_plant WHERE orders > 0 ORDER BY capacity_utilization_pct DESC;

\echo '=== By service level'
SELECT * FROM kpi.by_service_level ORDER BY orders DESC;

\echo '=== Top 10 customers by units'
SELECT * FROM kpi.top_customers ORDER BY units DESC LIMIT 10;
