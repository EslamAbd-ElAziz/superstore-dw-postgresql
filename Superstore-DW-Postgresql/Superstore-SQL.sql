SET search_path TO "Superstore";

-- 1) dim_customer
create TABLE dim_customer (
customer_Key SERIAL PRIMARY KEY,
customer_id TEXT UNIQUE NOT NULL,
customer_name TEXT NOT NULL,
segment TEXT NOT NULL
);
-- 2) dim_product
CREATE TABLE dim_product(
Product_Key SERIAL PRIMARY KEY, 
product_id TEXT UNIQUE NOT NULL,
product_name TEXT NOT NULL,
category TEXT NOT NULL,
sub_category TEXT NOT NULL
);

-- 3) dim_location
CREATE TABLE dim_location (
location_key SERIAL PRIMARY KEY,
city TEXT NOT NULL,
state TEXT NOT NULL,
postal_code int,
region TEXT NOT NULL,
country TEXT NOT NULL,
UNIQUE (city,state,postal_code,region)
);
-- 4) dim_ship_mode
create TABLE dim_ship_mode (
ship_mode_key SERIAL PRIMARY KEY,
ship_mode TEXT UNIQUE NOT NULL
);
-- 5) dim_date  
create TABLE dim_date (
date_key INT PRIMARY KEY,
full_date  DATE UNIQUE NOT NULL,
day        INT NOT NULL,
month      INT NOT NULL,
month_name TEXT NOT NULL,
quarter    INT NOT NULL,
year       INT NOT NULL,
weekday_name TEXT NOT NULL
);

-- 6) fact_sales
CREATE TABLE fact_sales (
    sales_key      SERIAL PRIMARY KEY,
    row_id         INT UNIQUE NOT NULL,      -- الرقم الأصلي من الداتا الخام
    order_id       TEXT NOT NULL,
    customer_key   INT NOT NULL REFERENCES dim_customer(customer_key),
    product_key    INT NOT NULL REFERENCES dim_product(product_key),
    location_key   INT NOT NULL REFERENCES dim_location(location_key),
    ship_mode_key  INT NOT NULL REFERENCES dim_ship_mode(ship_mode_key),
    order_date_key INT NOT NULL REFERENCES dim_date(date_key),
    ship_date_key  INT NOT NULL REFERENCES dim_date(date_key),
    sales          NUMERIC NOT NULL,
    quantity       INT NOT NULL,
    discount       NUMERIC NOT NULL,
    profit         NUMERIC NOT NULL,
    is_returned    BOOLEAN NOT NULL DEFAULT FALSE
);

-- insert the data into the Dim-Tables:
insert into dim_customer (customer_id,customer_name,segment) 
SELECT DISTINCT customer_id , customer_name , segment 
FROM orders;

insert into dim_product (product_id , product_name , category , sub_category) 
SELECT DISTINCT on (product_id) product_id , product_name , category , sub_category 
FROM orders
ORDER BY product_id, product_name;

-- to clear the Table after the duplicate error 
TRUNCATE Table dim_product CASCADE;

-- to check the duplication issue
select product_id , count(DISTINCT product_name) as Names , count(DISTINCT category) as cat
FROM orders
GROUP BY product_id
HAVING count(DISTINCT product_name)>1 or count(DISTINCT category)>1
ORDER BY Names DESC
LIMIT 10;

insert into dim_location (city,state,postal_code,region,country) 
SELECT DISTINCT city, state, postal_code, region,'country_region'
FROM orders;

INSERT INTO dim_ship_mode (ship_mode)
SELECT DISTINCT ship_mode
FROM orders;

insert into dim_date (date_key,full_date,day,month,month_name,quarter,year,weekday_name)
SELECT 
    to_char (d,'YYYYMMDD')::int as date_key,
    d::DATE as full_date,
    extract(day from d)::int as day,
    extract(month from d)::int as month,
    to_char (d,'month') as month_name,
    extract(quarter from d)::int as quarter,
    extract(YEAR from d)::int as year,
    to_char (d,'day') as weekday_name
FROM generate_series(
    (SELECT MIN(order_date) from orders),
    (SELECT max(ship_date) from orders),
    INTERVAL '1 day') as d;


INSERT INTO fact_sales (
    row_id, order_id, customer_key, product_key, location_key,
    ship_mode_key, order_date_key, ship_date_key,
    sales, quantity, discount, profit, is_returned
)
SELECT
    o.row_id,
    o.order_id,
    c.customer_key,
    p.product_key,
    l.location_key,
    sm.ship_mode_key,
    TO_CHAR(o.order_date, 'YYYYMMDD')::INT,
    TO_CHAR(o.ship_date, 'YYYYMMDD')::INT,
    o.sales,
    o.quantity,
    o.discount,
    o.profit,
    CASE WHEN r.order_id IS NOT NULL THEN TRUE ELSE FALSE END
FROM orders o
JOIN dim_customer  c  ON c.customer_id = o.customer_id
JOIN dim_product   p  ON p.product_id  = o.product_id
JOIN dim_location  l  ON l.city = o.city AND l.state = o.state
                      AND (l.postal_code = o.postal_code OR (l.postal_code IS NULL AND o.postal_code IS NULL))
                      AND l.region = o.region
JOIN dim_ship_mode sm ON sm.ship_mode = o.ship_mode
LEFT JOIN returns  r  ON r.order_id = o.order_id;

SELECT COUNT(*) FROM dim_product;


CREATE VIEW vw_profitability_report AS
SELECT
    d.year,
    l.region,
    p.category,
    p.sub_category,
    COUNT(f.sales_key)          AS total_orders,
    SUM(f.sales)                AS total_sales,
    SUM(f.profit)               AS total_profit,
    ROUND(SUM(f.profit) / NULLIF(SUM(f.sales), 0) * 100, 2) AS profit_margin_pct
FROM fact_sales f
JOIN dim_date    d ON d.date_key    = f.order_date_key
JOIN dim_location l ON l.location_key = f.location_key
JOIN dim_product  p ON p.product_key  = f.product_key
GROUP BY d.year, l.region, p.category, p.sub_category;

drop view if exists vw_profitability_report;
CREATE OR REPLACE FUNCTION get_customer_summary(p_customer_id text)
RETURNS TABLE (
    customer_name    text,
    segment          text,
    total_orders     BIGINT,
    total_sales      NUMERIC,
    total_profit     NUMERIC,
    returned_orders  BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.customer_name,
        c.segment,
        COUNT(f.sales_key)                              AS total_orders,
        SUM(f.sales)                                    AS total_sales,
        SUM(f.profit)                                   AS total_profit,
        SUM(CASE WHEN f.is_returned THEN 1 ELSE 0 END)  AS returned_orders
    FROM fact_sales f
    JOIN dim_customer c ON c.customer_key = f.customer_key
    WHERE c.customer_id = p_customer_id
    GROUP BY c.customer_name, c.segment;
END;
$$;

SELECT customer_id FROM dim_customer LIMIT 10;
SELECT * FROM get_customer_summary('RD-19930');

--Q1--Total Sales and Profit by Category and Sub-category:
select d.category,d.sub_category, round(sum(sales),0) as Total_sales , round(sum(profit),2) as total_profit,
 ROUND(SUM(f.profit) / NULLIF(SUM(f.sales), 0) * 100, 2)  AS profit_margin_pct
FROM fact_sales f
JOIN dim_product d on f.product_key = d.product_key
GROUP BY d.category, d.sub_category
ORDER BY total_profit DESC;
-- Q1.1-Total Sales and Profit by Category:
select DISTINCT d.category, round(sum(sales),0) as Total_sales , round(sum(profit),2) as total_profit,
    ROUND(SUM(f.profit) / NULLIF(SUM(f.sales), 0) * 100, 2)  AS profit_margin_pct
FROM fact_sales f
JOIN dim_product d on f.product_key = d.product_key
GROUP BY d.category
ORDER BY total_profit DESC;

--Q2-Top 10 Most Profitable Products:
select d.product_name,d.category, round(sum(sales),0) as Total_sales , round(sum(profit),2) as total_profit
FROM fact_sales f
JOIN dim_product d on f.product_key = d.product_key
GROUP BY d.product_name, d.category
ORDER BY total_profit DESC
LIMIT 10;

--Q3-Regions/states incurring losses (negative profit):
SELECT state ,total_profit from (
                select d.state, round(sum(profit),2) as total_profit
                FROM fact_sales f
                JOIN dim_location d on f.location_key = d.location_key
                GROUP BY d.state
)
WHERE total_profit < 0
ORDER BY total_profit ASC;

--Q4-Product Profitability Classification:
select d.product_name, round(sum(sales),0) as Total_sales , round(sum(profit),2),
            round(sum(profit) / NULLIF(sum(sales),0 )* 100,2) as margin_pct,
CASE 
    WHEN sum(profit) / NULLIF(sum(sales),0 ) >= 0.20 THEN 'High Margin'
    WHEN sum(profit) / NULLIF(sum(sales),0 ) >= 0.05 THEN 'Medium Margin'
    WHEN sum(profit) / NULLIF(sum(sales),0 ) >= 0     THEN 'Low Margin'
    ELSE  
        'Loss'
                END AS margin_category
FROM fact_sales f   
JOIN dim_product d on f.product_key = d.product_key
GROUP BY d.product_name
ORDER BY margin_pct DESC;

--Q5-Year-over-Year Profit Growth by Category:
WITH yearly_profit AS(SELECT d.year, p.category,round(sum(profit),2) as total_profit
FROM fact_sales f
JOIN dim_date d on f.order_date_key = d.date_key
JOIN dim_product p on f.product_key = p.product_key
GROUP BY d.year , p.category
)
SELECT cur.category, cur.YEAR, round(cur.total_profit/NULLIF(prev.total_profit,0)*100,2) as growth_pct
FROM yearly_profit cur
LEFT JOIN yearly_profit prev on prev.category = cur.category AND prev.YEAR= cur.YEAR-1
ORDER BY cur.category, cur.YEAR DESC;

--Q6-Top 10 Customers by Total Sales
select c.customer_name, c.segment, 
                                count(sales_key)as total_Orders,
                                round(SUM(profit),2)as total_profit,
                                round(sum(sales),0) as Total_sales 
FROM fact_sales f
JOIN dim_customer c on c.customer_key = f.customer_key 
GROUP BY c.customer_key , c.segment
ORDER BY Total_sales DESC
LIMIT 10;

--Q7-Segments | Segment Performance Comparison
SELECT c.segment,
                COUNT(DISTINCT c.customer_key) as total_customers,
                                count(sales_key)as total_Orders,
                                round(SUM(profit),2)as total_profit,
                                round(sum(sales),0) as Total_sales, 
                                round(AVG(sales),2) as avg_order_value
FROM fact_sales as f
JOIN dim_customer as c on c.customer_key = f.customer_key
GROUP BY c.segment
ORDER BY Total_sales DESC;

--Q8-Customers with Above - Average Return Rate:-
WITH customer_return_rate AS (
    SELECT c.customer_key, customer_name ,  count(sales_key) as total_orders,
    SUM(CASE 
        WHEN is_returned THEN 1 ELSE 0 END)returned_orders,
    round(SUM(CASE 
        WHEN is_returned THEN 1 ELSE 0 END)::NUMERIC / count(sales_key) * 100 , 2) as  return_rate_pct
FROM fact_sales as f
JOIN dim_customer c on c.customer_key = f.customer_key
GROUP BY customer_name , c.customer_key 
)
SELECT * 
FROM customer_return_rate
WHERE return_rate_pct > (SELECT AVG(return_rate_pct)FROM customer_return_rate
)
ORDER BY return_rate_pct DESC;

--Q9-Repeat vs One-Time Customer Classification:-
SELECT c.customer_key , c.segment, count(distinct order_id) as distinct_orders , sum(sales) as total_sales,
            case 
                WHEN count(distinct order_id) = 1 THEN 'One-Time Customer'
                WHEN count(distinct order_id) BETWEEN 2 AND 5 THEN 'Repeat Customer'
                ELSE 'Loyal Customer'
END AS customer_type
from fact_sales f
JOIN dim_customer c on c.customer_key = f.customer_key
GROUP BY c.customer_key , c.segment
ORDER BY distinct_orders DESC;

--Q10-Customers Who Never Returned a Product:
SELECT 
DISTINCT customer_id,customer_name, segment
from dim_customer c
join fact_sales f on c.customer_key = f.customer_key
where not exists
            (select * from fact_sales f
            where f.customer_key=c.customer_key and f.is_returned = true)
order by customer_name;

--Q11-Monthly Sales Trend for a Specific Year:
SELECT 
month, 
month_name,
count(sales_key) as total_orders,
round(SUM(sales),0) as monthly_sales,
round(SUM(profit),2) as monthly_profit
FROM fact_sales f
JOIN dim_date d on d.date_key = f.order_date_key
WHERE year = 2019
GROUP BY month, month_name
ORDER BY month;

--Q12-Quarterly Sales Comparison:
WITH quarterly_sales AS (
    SELECT 
        quarter, 
        year,
        count(sales_key) as total_orders,
        round(SUM(sales),0) as quarterly_sales,
        round(SUM(profit),2) as quarterly_profit
    FROM fact_sales f
    JOIN dim_date d on d.date_key = f.order_date_key
    GROUP BY quarter, year
)
select quarter,year,quarterly_sales,
round(quarterly_sales / sum(quarterly_sales) OVER(PARTITION BY year) * 100, 2) as pct_of_year_sales
from quarterly_sales
ORDER BY year, quarter;

--Q13-Shipping Mode Performance:
SELECT 
    sm.ship_mode,
    count(sales_key) as total_orders,
    round(SUM(sales),0) as total_sales,
    round(SUM(profit),2) as total_profit,
    round(AVG(sales),2) as avg_order_value,
    round(AVG(sd.full_date - od.full_date),2) as avg_shipping_time,
    case
        when AVG(sd.full_date - od.full_date) <= 1 THEN 'Fast'
        when AVG(sd.full_date - od.full_date) <= 4 THEN 'Medium'
        else 'Slow'
    end as shipping_speed_category
FROM fact_sales f
JOIN dim_ship_mode sm on sm.ship_mode_key = f.ship_mode_key
join dim_date as od on od.date_key = f.order_date_key
join dim_date as sd on sd.date_key = f.ship_date_key
GROUP BY sm.ship_mode
order by avg_shipping_time DESC;

--Q14-Products with Declining Year-over-Year Sales:
WITH yearly_product_sales AS (
SELECT 
        p.product_key,
        p.product_name,
        d.year,
        round(sum(f.sales),0) as total_sales
FROM fact_sales f
join dim_product p on p.product_key = f.product_key
join dim_date d on d.date_key = f.order_date_key
group by p.product_key, p.product_name, d.year
)

SELECT cur.product_name, cur.year, prev.total_sales as previous_year_sales, cur.total_sales as current_year_sales,
    round((cur.total_sales - prev.total_sales) / prev.total_sales * 100, 2) AS change_pct
from yearly_product_sales cur
join yearly_product_sales prev ON prev.product_key = cur.product_key 
and prev.year = cur.year - 1
where cur.total_sales < prev.total_sales
ORDER BY change_pct ASC;

--Q15-Top 5 States by Total Profitability:
SELECT 
    l.state,l.region,
    count(distinct f.sales_key) as total_orders,
    round(SUM(f.sales),0) as total_sales,
    round(SUM(f.profit),2) as total_profit,
    round(SUM(f.profit) / NULLIF(SUM(f.sales), 0) * 100, 2) AS profit_margin_pct
FROM fact_sales f
JOIN dim_location l on l.location_key = f.location_key
GROUP BY l.state , l.region
ORDER BY total_profit DESC
LIMIT 5;

--Optimize queries for performance:-
-- Foreign Keys
CREATE INDEX idx_fact_customer   
ON fact_sales(customer_key);
CREATE INDEX idx_fact_product    
ON fact_sales(product_key);
CREATE INDEX idx_fact_location   
ON fact_sales(location_key);
CREATE INDEX idx_fact_orderdate  
ON fact_sales(order_date_key);
CREATE INDEX idx_fact_shipdate   
ON fact_sales(ship_date_key);

-- is_returned, order_id
CREATE INDEX idx_fact_returned  
 ON fact_sales(is_returned);
CREATE INDEX idx_fact_orderid   
 ON fact_sales(order_id);

-- dim_date 
CREATE INDEX idx_date_year       
ON dim_date(year);

--Test the performance of a query using EXPLAIN ANALYZE:
EXPLAIN ANALYZE
SELECT * FROM fact_sales WHERE customer_key = 5;