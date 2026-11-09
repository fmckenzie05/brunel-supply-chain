-- Brunel Supply Chain Logistics Problem Dataset -> PostgreSQL
-- Source: Kalganova & Dzalbs (2019), Brunel University London, CC BY 4.0
--   https://doi.org/10.17633/rd.brunel.7558679.v2
--
-- Run in psql (SQL Shell), connected to any database:
--   \i '/path/to/Brunel_Supply_Chain/load_brunel.sql'
-- Note: \copy, \c, \cd and \gexec are psql commands. This will NOT run
-- in pgAdmin's Query Tool; use psql or pgAdmin's PSQL Tool.

\set ON_ERROR_STOP on

-- Create the database if it doesn't exist, then connect to it
SELECT 'CREATE DATABASE supply_chain'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'supply_chain')\gexec
\c supply_chain

\cd '/path/to/Brunel_Supply_Chain'

BEGIN;

CREATE SCHEMA IF NOT EXISTS brunel;
SET search_path TO brunel;

DROP TABLE IF EXISTS order_list, freight_rates, products_per_plant,
                     plant_ports, vmi_customers, wh_capacities, wh_costs CASCADE;

-- Dimension tables -----------------------------------------------------------

CREATE TABLE wh_costs (
    plant_code      text PRIMARY KEY,
    cost_per_unit   numeric(12,6) NOT NULL          -- $ per unit stored
);

CREATE TABLE wh_capacities (
    plant_code      text PRIMARY KEY REFERENCES wh_costs (plant_code),
    daily_capacity  integer NOT NULL                -- orders per day
);

CREATE TABLE plant_ports (
    plant_code      text NOT NULL REFERENCES wh_costs (plant_code),
    port            text NOT NULL,
    PRIMARY KEY (plant_code, port)
);

-- No FK here: source lists plant 'CND9' which has no cost/capacity record
CREATE TABLE products_per_plant (
    plant_code      text   NOT NULL,
    product_id      bigint NOT NULL,
    PRIMARY KEY (plant_code, product_id)
);

CREATE TABLE vmi_customers (
    plant_code      text NOT NULL REFERENCES wh_costs (plant_code),
    customer        text NOT NULL,
    PRIMARY KEY (plant_code, customer)
);

-- Rate table (source has duplicate rate rows, so it uses a surrogate key) ----

CREATE TABLE freight_rates (
    rate_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier         text          NOT NULL,
    orig_port       text          NOT NULL,
    dest_port       text          NOT NULL,
    min_weight      numeric(12,2) NOT NULL,
    max_weight      numeric(12,2) NOT NULL,
    service_level   text          NOT NULL,         -- DTD / DTP / CRF
    minimum_cost    numeric(12,4) NOT NULL,
    rate            numeric(12,4) NOT NULL,         -- $ per weight unit
    mode            text          NOT NULL,         -- AIR / GROUND
    transit_days    integer       NOT NULL,
    carrier_type    text
);

-- Fact table -----------------------------------------------------------------

CREATE TABLE order_list (
    order_id        numeric(14,1) PRIMARY KEY,
    order_date      date          NOT NULL,
    origin_port     text          NOT NULL,
    carrier         text          NOT NULL,
    transit_days    integer       NOT NULL,         -- TPT
    service_level   text          NOT NULL,
    ship_ahead_days integer       NOT NULL,
    ship_late_days  integer       NOT NULL,
    customer        text          NOT NULL,
    product_id      bigint        NOT NULL,
    plant_code      text          NOT NULL REFERENCES wh_costs (plant_code),
    dest_port       text          NOT NULL,
    unit_quantity   integer       NOT NULL,
    weight          numeric(12,2) NOT NULL
);

-- Load (column order matches the CSV headers) --------------------------------

\copy wh_costs FROM 'WhCosts.csv' WITH (FORMAT csv, HEADER true)
\copy wh_capacities FROM 'WhCapacities.csv' WITH (FORMAT csv, HEADER true)
\copy plant_ports FROM 'PlantPorts.csv' WITH (FORMAT csv, HEADER true)
\copy products_per_plant FROM 'ProductsPerPlant.csv' WITH (FORMAT csv, HEADER true)
\copy vmi_customers FROM 'VmiCustomers.csv' WITH (FORMAT csv, HEADER true)
\copy freight_rates (carrier, orig_port, dest_port, min_weight, max_weight, service_level, minimum_cost, rate, mode, transit_days, carrier_type) FROM 'FreightRates.csv' WITH (FORMAT csv, HEADER true)
\copy order_list FROM 'OrderList.csv' WITH (FORMAT csv, HEADER true)

-- Clean-up: source pads mode values with trailing spaces ("AIR   ")
UPDATE freight_rates SET mode = trim(mode);

CREATE INDEX ON order_list (order_date);
CREATE INDEX ON order_list (carrier);
CREATE INDEX ON order_list (customer);
CREATE INDEX ON freight_rates (carrier, orig_port, dest_port, service_level);

COMMIT;

ANALYZE;

-- Sanity check: expected 9215 / 1540 / 2036 / 22 / 19 / 19 / 14
SELECT 'order_list' AS table_name, count(*) FROM brunel.order_list
UNION ALL SELECT 'freight_rates', count(*) FROM brunel.freight_rates
UNION ALL SELECT 'products_per_plant', count(*) FROM brunel.products_per_plant
UNION ALL SELECT 'plant_ports', count(*) FROM brunel.plant_ports
UNION ALL SELECT 'wh_costs', count(*) FROM brunel.wh_costs
UNION ALL SELECT 'wh_capacities', count(*) FROM brunel.wh_capacities
UNION ALL SELECT 'vmi_customers', count(*) FROM brunel.vmi_customers;
