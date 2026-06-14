select * from customers;
select * from orders;

/* clean layer */
CREATE TABLE orders_clean AS
SELECT DISTINCT
    order_id,
    customer_id,
    order_purchase_timestamp::timestamp AS order_purchase_timestamp,
    order_status
FROM orders
WHERE order_purchase_timestamp IS NOT NULL
  AND order_id IS NOT NULL
  AND customer_id IS NOT NULL;

select count(*)from orders_clean;

select count(*)from orders;
select count(*) from customers;

SELECT order_id, COUNT(*)
FROM orders
GROUP BY order_id
HAVING COUNT(*) > 1;

SELECT COUNT(*)
FROM orders
WHERE customer_id IS NULL;

SELECT COUNT(*)
FROM orders
WHERE order_purchase_timestamp IS NULL;

select count(distinct customer_id), count(distinct customer_unique_id)
from customers;


/* 고객별 주문 정보 */
DROP TABLE IF EXISTS customer_summary;

create table customer_summary as
select
	c.customer_unique_id,
	min(o.order_purchase_timestamp )as first_order_date,
	max(o.order_purchase_timestamp )as last_order_date,
	count(distinct o.order_id) as order_count
from orders o
join customers c
	on o.customer_id = c.customer_id 
where o.order_status = 'delivered'
group by c.customer_unique_id;
commit;

select*from customer_summary;

SELECT COUNT(*) AS total_customers
FROM customer_summary;

-- 전체 고객
SELECT COUNT(DISTINCT customer_unique_id) AS total_all_customers
FROM customers;

-- delivered 고객
SELECT COUNT(*) AS delivered_customers
FROM customer_summary;

SELECT
    CASE 
        WHEN order_count = 1 THEN '1회 구매'
        ELSE '2회 이상 구매'
    END AS customer_type,
    COUNT(*) AS customer_cnt
FROM customer_summary
GROUP BY customer_type;


SELECT *
FROM customer_summary
WHERE order_count >= 2;



/*주문 간격 계산 */
select 
c.customer_unique_id, o.order_purchase_timestamp,
LAG(o.order_purchase_timestamp) over (
	partition by c.customer_unique_id
	order by o.order_purchase_timestamp
	)as prev_order_date
from orders o
join customers c
	on o.customer_id = c.customer_id 
where o.order_status = 'delivered';

select *
from(
	select 
	c.customer_unique_id, o.order_purchase_timestamp,
	LAG(o.order_purchase_timestamp) over (
		partition by c.customer_unique_id
		order by o.order_purchase_timestamp
	)as prev_order_date
from orders o
join customers c
	on o.customer_id = c.customer_id 
where o.order_status = 'delivered'
)t
where t.prev_order_date is not null;

/* 구매 간격 order_gap 계산 */
SELECT *,
       DATE_PART(
           'day',
           order_purchase_timestamp::timestamp 
           - prev_order_date::timestamp
       ) AS order_gap
FROM (
    SELECT
        c.customer_unique_id,
        o.order_purchase_timestamp,
        LAG(o.order_purchase_timestamp) OVER (
            PARTITION BY c.customer_unique_id 
            ORDER BY o.order_purchase_timestamp
        ) AS prev_order_date
    FROM orders o
    JOIN customers c 
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
) t
WHERE prev_order_date IS NOT NULL;


/* avg_order_gap 계산 */

create table order_gap as 
select
	c.customer_unique_id,
	o.order_id,
	o.order_purchase_timestamp,
	LAG(o.order_purchase_timestamp)over(
		partition by c.customer_unique_id
		order by o.order_purchase_timestamp
	)as prev_order_date,
	date_part( 
		'day',
		o.order_purchase_timestamp - 
	 	lag(o.order_purchase_timestamp) over (
			partition by c.customer_unique_id
			order by o.order_purchase_timestamp
			)
		)as order_gap
from orders_clean o
join customers c
	on o.customer_id = c.customer_id
where o.order_status = 'delivered';
	
select * from order_gap;
	
DROP TABLE IF EXISTS avg_order_gap;
create table avg_order_gap as
select
	customer_unique_id,
	avg(order_gap) as avg_order_gap
from order_gap
where order_gap is not null
group by customer_unique_id;

select*from avg_order_gap;
	

-- churn 계산하고 최종 마트 만들
CREATE TABLE customer_summary_final AS
SELECT
    cs.customer_unique_id AS customer_id,
    cs.first_order_date AS first_order,
    cs.last_order_date AS last_order,
    cs.order_count,
    ag.avg_order_gap,
    
    -- 기준일 (고정)
    DATE '2018-10-30' AS reference_date,
    
    -- 마지막 주문 이후 경과일
    (DATE '2018-10-30' - cs.last_order_date::date) AS days_since_last,
    
    -- 고정 churn (90일 기준)
    CASE
        WHEN (DATE '2018-10-30' - cs.last_order_date::date) > 90 THEN 1
        ELSE 0
    END AS churn_90,
    
    -- 동적 churn (개인화)
    CASE
        WHEN ag.avg_order_gap IS NULL THEN 0
        WHEN (DATE '2018-10-30' - cs.last_order_date::date) > ag.avg_order_gap * 3 THEN 1
        ELSE 0
    END AS churn_dynamic    

FROM customer_summary cs
LEFT JOIN avg_order_gap ag
    ON cs.customer_unique_id = ag.customer_unique_id;

select * from customer_summary_final;
	
-- 매출 추가
create table customer_summary_final_v2 as
with revenue as (
    select 
        c.customer_unique_id,
        sum(op.payment_value) as total_revenue
    from orders o
    join order_payments op
        on o.order_id = op.order_id
    join customers c
        on o.customer_id = c.customer_id 
    group by c.customer_unique_id
)
select 
    csf.*,
    coalesce(r.total_revenue, 0) as total_revenue
from customer_summary_final csf
left join revenue r
on csf.customer_id = r.customer_unique_id;
SELECT * FROM customer_summary_final_v2;

select count(*) from customer_summary_final;


CREATE TABLE median_order_gap AS
SELECT
    customer_unique_id,
    PERCENTILE_CONT(0.5) 
        WITHIN GROUP (ORDER BY order_gap) AS median_order_gap
FROM order_gap
WHERE order_gap IS NOT NULL
GROUP BY customer_unique_id;

SELECT * FROM median_order_gap;

select count(*) from avg_order_gap;

DROP TABLE IF EXISTS customer_gap_summary;

CREATE TABLE customer_gap_summary AS
SELECT
    customer_unique_id,
    AVG(order_gap) AS avg_order_gap,
    PERCENTILE_CONT(0.5) 
        WITHIN GROUP (ORDER BY order_gap) AS median_order_gap
FROM order_gap
WHERE order_gap IS NOT NULL
GROUP BY customer_unique_id;

SELECT * FROM customer_gap_summary;

	
SELECT 
    COUNT(*) AS diff_customer_count
FROM customer_gap_summary
WHERE avg_order_gap <> median_order_gap;



