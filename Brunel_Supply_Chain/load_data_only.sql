-- Loads all 7 Brunel CSVs into the existing brunel tables in one go.
-- Run in psql while connected to supply_chain:
--   \i '/path/to/Brunel_Supply_Chain/load_data_only.sql'

\set ON_ERROR_STOP on
\set ECHO queries

BEGIN;

TRUNCATE brunel.order_list, brunel.freight_rates, brunel.products_per_plant,
         brunel.plant_ports, brunel.vmi_customers, brunel.wh_capacities,
         brunel.wh_costs RESTART IDENTITY;

\copy brunel.wh_costs FROM '/path/to/Brunel_Supply_Chain/WhCosts.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.wh_capacities FROM '/path/to/Brunel_Supply_Chain/WhCapacities.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.plant_ports FROM '/path/to/Brunel_Supply_Chain/PlantPorts.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.products_per_plant FROM '/path/to/Brunel_Supply_Chain/ProductsPerPlant.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.vmi_customers FROM '/path/to/Brunel_Supply_Chain/VmiCustomers.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.freight_rates (carrier, orig_port, dest_port, min_weight, max_weight, service_level, minimum_cost, rate, mode, transit_days, carrier_type) FROM '/path/to/Brunel_Supply_Chain/FreightRates.csv' WITH (FORMAT csv, HEADER true)
\copy brunel.order_list FROM '/path/to/Brunel_Supply_Chain/OrderList.csv' WITH (FORMAT csv, HEADER true)

UPDATE brunel.freight_rates SET mode = trim(mode);

COMMIT;

-- Expected: 9215 / 1540 / 2036 / 22 / 19 / 19 / 14
SELECT 'order_list' AS table_name, count(*) FROM brunel.order_list
UNION ALL SELECT 'freight_rates', count(*) FROM brunel.freight_rates
UNION ALL SELECT 'products_per_plant', count(*) FROM brunel.products_per_plant
UNION ALL SELECT 'plant_ports', count(*) FROM brunel.plant_ports
UNION ALL SELECT 'wh_costs', count(*) FROM brunel.wh_costs
UNION ALL SELECT 'wh_capacities', count(*) FROM brunel.wh_capacities
UNION ALL SELECT 'vmi_customers', count(*) FROM brunel.vmi_customers;
