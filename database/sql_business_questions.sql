-- Q01: How many active customers does the platform currently have, by country?
-- Counts each customer once and combines recognized country aliases.
WITH country_aliases(alias, country) AS (
    VALUES
        ('us', 'United States'), ('in', 'India'), ('bharat', 'India'),
        ('de', 'Germany'), ('ca', 'Canada'), ('uae', 'United Arab Emirates'),
        ('fr', 'France'), ('mx', 'Mexico'), ('za', 'South Africa'),
        ('ng', 'Nigeria'), ('br', 'Brazil'), ('ar', 'Argentina'),
        ('jp', 'Japan'), ('kr', 'South Korea'), ('s korea', 'South Korea'),
        ('au', 'Australia'), ('it', 'Italy'), ('pl', 'Poland'),
        ('id', 'Indonesia'), ('ph', 'Philippines'), ('es', 'Spain')
), active_customers AS (
    SELECT DISTINCT c.customer_id,
           COALESCE(a.country, NULLIF(TRIM(c.country), ''), 'Unknown') AS country
    FROM customers c
    JOIN subscriptions s ON s.customer_id = c.customer_id
    LEFT JOIN country_aliases a ON a.alias = LOWER(TRIM(c.country))
    WHERE s.subscription_status = 'Active'
)
SELECT
    country,
    COUNT(*) AS active_customer_count
FROM active_customers
GROUP BY country
ORDER BY active_customer_count DESC, country;


-- Alternative: same count without combining country aliases.
SELECT
    c.country,
    COUNT(DISTINCT c.customer_id) AS active_customer_count
FROM customers AS c
JOIN subscriptions AS s ON s.customer_id = c.customer_id
WHERE s.subscription_status = 'Active'
GROUP BY c.country
ORDER BY active_customer_count DESC, c.country;


-- Q02: Total and average monthly revenue by plan (active subscriptions only).
SELECT
    p.plan_name,
    COUNT(s.subscription_id) AS active_subscription_count,
    COALESCE(SUM(s.monthly_price), 0) AS total_monthly_revenue,
    ROUND(AVG(s.monthly_price), 2) AS average_monthly_revenue_per_subscription
FROM subscription_plans AS p
LEFT JOIN subscriptions AS s
    ON s.plan_id = p.plan_id
   AND s.subscription_status = 'Active'
GROUP BY p.plan_id, p.plan_name
ORDER BY total_monthly_revenue DESC, p.plan_name;


-- Q03: Overall churn rate (% of customers with churned = true).
SELECT
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE cl.churned IS TRUE)
        / NULLIF(COUNT(c.customer_id), 0),
        2
    ) AS churn_rate_percent
FROM customers AS c
LEFT JOIN churn_labels AS cl
    ON cl.customer_id = c.customer_id;


-- Q04:Which acquisition channel has brought in the most customers, and what is the churn rate for each channel? 
SELECT
    COALESCE(NULLIF(TRIM(c.acquisition_channel), ''), 'Unknown') AS acquisition_channel,
    --c.acquisition_channel,
    COUNT(*) AS customer_count,
    COUNT(*) FILTER (WHERE cl.churned IS TRUE) AS churned_customer_count,
    --SUM(CASE WHEN cl.churned = TRUE THEN 1 ELSE 0 END) AS churned_customer_count
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE cl.churned IS TRUE)
        / NULLIF(COUNT(*), 0),
        2
    ) AS churn_rate_percent
FROM customers AS c
LEFT JOIN churn_labels AS cl
    ON cl.customer_id = c.customer_id
GROUP BY COALESCE(NULLIF(TRIM(c.acquisition_channel), ''), 'Unknown')
ORDER BY customer_count DESC, acquisition_channel;


-- Q05: Average customer age by subscription plan.
SELECT
    p.plan_name,
    ROUND(AVG(c.age), 2) AS average_customer_age
FROM customers AS c
JOIN subscriptions AS s ON s.customer_id = c.customer_id
JOIN subscription_plans AS p ON p.plan_id = s.plan_id
GROUP BY p.plan_name
ORDER BY p.plan_name;


-- Q07: What is the average completion percentage by content type and genre?
SELECT
    c.content_type,
    c.genre,
    ROUND(AVG(v.completion_percentage), 2) AS average_completion_percentage
FROM viewing_activity AS v
JOIN content AS c ON c.content_id = v.content_id
GROUP BY c.content_type, c.genre
ORDER BY c.content_type, c.genre;


-- Q08: Failed payments in each of the last 12 months (including zero-count months).
SELECT
    months.month::date AS month,
    COUNT(p.payment_id) AS failed_payment_count
FROM GENERATE_SERIES(
    DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '11 months',
    DATE_TRUNC('month', CURRENT_DATE),
    INTERVAL '1 month'
) AS months(month)
LEFT JOIN payments AS p
    ON p.payment_date >= months.month
   AND p.payment_date < months.month + INTERVAL '1 month'
   AND p.payment_status = 'Failed'
GROUP BY months.month
ORDER BY months.month;


-- Q09: Average resolution time by issue category.
SELECT
    issue_category,
    ROUND(AVG(resolution_time_hours), 2) AS average_resolution_hours
FROM support_tickets
GROUP BY issue_category
ORDER BY issue_category;


-- Q10: Distribution of satisfaction scores for resolved or closed tickets.
SELECT
    customer_satisfaction_score,
    COUNT(*) AS ticket_count
FROM support_tickets
WHERE ticket_status IN ('Resolved', 'Closed')
GROUP BY customer_satisfaction_score
ORDER BY customer_satisfaction_score;


-- Q11: Total viewing minutes by device type.
SELECT
    device_type,
    ROUND(SUM(watch_duration_minutes), 2) AS total_viewing_minutes
FROM viewing_activity
GROUP BY device_type
ORDER BY total_viewing_minutes DESC;


-- Q12: Average feedback rating by sentiment.
SELECT
    sentiment_label,
    ROUND(AVG(rating), 2) AS average_rating
FROM customer_feedback
GROUP BY sentiment_label
ORDER BY sentiment_label;


-- Q13: Customer signups by acquisition channel and calendar year.
SELECT
    EXTRACT(YEAR FROM registration_date)::int AS signup_year,
    acquisition_channel,
    COUNT(*) AS customer_count
FROM customers
GROUP BY signup_year, acquisition_channel
ORDER BY signup_year, customer_count DESC;


-- Q14: Percentage of customers with auto-renew turned off.
SELECT
    ROUND(
        100.0 * COUNT(DISTINCT customer_id) FILTER (WHERE auto_renew = FALSE)
        / COUNT(DISTINCT customer_id),
        2
    ) AS auto_renew_off_percent
FROM subscriptions;


-- Q15: Customers with more than three support tickets.
SELECT
    customer_id,
    COUNT(*) AS ticket_count
FROM support_tickets
GROUP BY customer_id
HAVING COUNT(*) > 3
ORDER BY ticket_count DESC, customer_id;


-- Q16: Rank plans by monthly price multiplied by active subscription count.
SELECT
    RANK() OVER (
        ORDER BY p.monthly_price * COUNT(s.subscription_id) DESC
    ) AS revenue_rank,
    p.plan_name,
    COUNT(s.subscription_id) AS active_subscription_count,
    p.monthly_price * COUNT(s.subscription_id) AS total_monthly_revenue
FROM subscription_plans AS p
LEFT JOIN subscriptions AS s
    ON s.plan_id = p.plan_id
   AND s.subscription_status = 'Active'
GROUP BY p.plan_id, p.plan_name, p.monthly_price
ORDER BY revenue_rank;


-- Q17: For each customer, use ROW_NUMBER() to identify their most recent support ticket and return only that row.
SELECT *
FROM (
    SELECT
        t.*,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY ticket_date DESC, ticket_id DESC
        ) AS row_num
    FROM support_tickets AS t
) AS ranked_tickets
WHERE row_num = 1;


-- Q18: Three-month moving average of new customer registrations.
--Calculate a 3-month moving average of new customer registrations using a window function.
SELECT
    signup_month,
    new_customers,
    ROUND(AVG(new_customers) OVER (
        ORDER BY signup_month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 2) AS three_month_moving_average
FROM (
    SELECT
        DATE_TRUNC('month', registration_date)::date AS signup_month,
        COUNT(*) AS new_customers
    FROM customers
    GROUP BY DATE_TRUNC('month', registration_date)
) AS monthly_signups
ORDER BY signup_month;


-- Q19: Customers whose watch time fell in the latest data month.
WITH months AS (
    SELECT GENERATE_SERIES(
        DATE_TRUNC('month', MAX(viewing_date)) - INTERVAL '1 month',
        DATE_TRUNC('month', MAX(viewing_date)),
        INTERVAL '1 month'
    ) AS month
    FROM viewing_activity
), monthly_watch_time AS (
    SELECT c.customer_id, m.month,
           COALESCE(SUM(v.watch_duration_minutes), 0) AS watch_minutes
    FROM customers AS c
    CROSS JOIN months AS m
    LEFT JOIN viewing_activity AS v
        ON v.customer_id = c.customer_id
       AND v.viewing_date >= m.month
       AND v.viewing_date < m.month + INTERVAL '1 month'
    GROUP BY c.customer_id, m.month
), watch_time_changes AS (
    SELECT customer_id, month, watch_minutes,
           LAG(watch_minutes) OVER (
               PARTITION BY customer_id ORDER BY month
           ) AS previous_month_minutes
    FROM monthly_watch_time
)
SELECT customer_id, previous_month_minutes, watch_minutes AS latest_month_minutes
FROM watch_time_changes
WHERE month = (SELECT MAX(month) FROM months)
  AND watch_minutes < previous_month_minutes
ORDER BY customer_id;


-- Q20: Cohort retention at 1, 3, and 6 months after registration.
SELECT
    DATE_TRUNC('month', c.registration_date)::date AS cohort_month,
    CASE WHEN DATE_TRUNC('month', c.registration_date) + INTERVAL '2 months' <= CURRENT_DATE
         THEN ROUND(100.0 * COUNT(*) FILTER (
             WHERE cl.churned = FALSE
                OR cl.churn_date > DATE_TRUNC('month', c.registration_date) + INTERVAL '1 month'
         ) / COUNT(*), 2) END AS active_after_1_month_percent,
    CASE WHEN DATE_TRUNC('month', c.registration_date) + INTERVAL '4 months' <= CURRENT_DATE
         THEN ROUND(100.0 * COUNT(*) FILTER (
             WHERE cl.churned = FALSE
                OR cl.churn_date > DATE_TRUNC('month', c.registration_date) + INTERVAL '3 months'
         ) / COUNT(*), 2) END AS active_after_3_months_percent,
    CASE WHEN DATE_TRUNC('month', c.registration_date) + INTERVAL '7 months' <= CURRENT_DATE
         THEN ROUND(100.0 * COUNT(*) FILTER (
             WHERE cl.churned = FALSE
                OR cl.churn_date > DATE_TRUNC('month', c.registration_date) + INTERVAL '6 months'
         ) / COUNT(*), 2) END AS active_after_6_months_percent
FROM customers AS c
LEFT JOIN churn_labels AS cl ON cl.customer_id = c.customer_id
GROUP BY cohort_month
ORDER BY cohort_month;


-- Q21: Five highest country churn-rate ranks.
SELECT
    country,
    ROUND(churn_rate, 2) AS churn_rate_percent,
    churn_rank
FROM (
    SELECT
        c.country,
        100.0 * COUNT(*) FILTER (WHERE cl.churned = TRUE) / COUNT(*) AS churn_rate,
        DENSE_RANK() OVER (
            ORDER BY COUNT(*) FILTER (WHERE cl.churned = TRUE)::decimal / COUNT(*) DESC
        ) AS churn_rank
    FROM customers AS c
    LEFT JOIN churn_labels AS cl ON cl.customer_id = c.customer_id
    GROUP BY c.country
) AS ranked_countries
WHERE churn_rank <= 5
ORDER BY churn_rank, country;


-- Q22: Running total of successful payments for each customer.
SELECT
    customer_id,
    payment_date,
    payment_id,
    amount,
    SUM(amount) OVER (
        PARTITION BY customer_id
        ORDER BY payment_date, payment_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM payments
WHERE payment_status = 'Success'
ORDER BY customer_id, payment_date, payment_id;


-- Q23: Customers whose watch time declined for three consecutive months.
WITH monthly_watch AS (
    SELECT
        customers.customer_id,
        months.month,
        COALESCE(SUM(viewing_activity.watch_duration_minutes), 0) AS watch_minutes
    FROM (SELECT DISTINCT customer_id FROM viewing_activity) AS customers
    CROSS JOIN GENERATE_SERIES(
        DATE_TRUNC('month', (SELECT MAX(viewing_date) FROM viewing_activity)) - INTERVAL '2 months',
        DATE_TRUNC('month', (SELECT MAX(viewing_date) FROM viewing_activity)),
        INTERVAL '1 month'
    ) AS months(month)
    LEFT JOIN viewing_activity
        ON viewing_activity.customer_id = customers.customer_id
       AND viewing_activity.viewing_date >= months.month
       AND viewing_activity.viewing_date < months.month + INTERVAL '1 month'
    GROUP BY customers.customer_id, months.month
)
SELECT
    customer_id,
    two_months_ago AS watch_time_two_months_ago,
    previous_month AS watch_time_previous_month,
    watch_minutes AS watch_time_latest_month
FROM (
    SELECT
        customer_id,
        month,
        watch_minutes,
        LAG(watch_minutes, 2) OVER (PARTITION BY customer_id ORDER BY month) AS two_months_ago,
        LAG(watch_minutes) OVER (PARTITION BY customer_id ORDER BY month) AS previous_month
    FROM monthly_watch
) AS monthly_changes
WHERE month = DATE_TRUNC('month', (SELECT MAX(viewing_date) FROM viewing_activity))
  AND watch_minutes < previous_month
  AND previous_month < two_months_ago
ORDER BY customer_id;


-- Q24: Monthly churn rate for the last 12 months.
SELECT
    m.month::date AS month,
    COUNT(DISTINCT cl.customer_id) AS churned_customers,
    COUNT(DISTINCT s.customer_id) AS active_at_month_start,
    ROUND(
        100.0 * COUNT(DISTINCT cl.customer_id)
        / NULLIF(COUNT(DISTINCT s.customer_id), 0),
        2
    ) AS churn_rate_percent
FROM GENERATE_SERIES(
    DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '11 months',
    DATE_TRUNC('month', CURRENT_DATE),
    INTERVAL '1 month'
) AS m(month)
LEFT JOIN churn_labels AS cl
    ON cl.churned = TRUE
   AND cl.churn_date >= m.month
   AND cl.churn_date < m.month + INTERVAL '1 month'
LEFT JOIN subscriptions AS s
    ON s.subscription_start_date <= m.month
   AND COALESCE(s.subscription_end_date, s.cancellation_date, CURRENT_DATE) >= m.month
GROUP BY m.month
ORDER BY m.month;


-- Q25: Customer retention rate by acquisition channel.
SELECT
    c.acquisition_channel,
    ROUND(
        100.0 * COUNT(DISTINCT c.customer_id) FILTER (
            WHERE s.subscription_status = 'Active'
        ) / COUNT(DISTINCT c.customer_id),
        2
    ) AS retention_rate_percent
FROM customers AS c
LEFT JOIN subscriptions AS s ON s.customer_id = c.customer_id
GROUP BY c.acquisition_channel
ORDER BY retention_rate_percent DESC;


-- Q26: Customer lifetime spend and spend quartile.
WITH customer_spend AS (
    SELECT
        c.customer_id,
        COALESCE(SUM(p.amount), 0) AS lifetime_spend
    FROM customers AS c
    LEFT JOIN payments AS p
        ON p.customer_id = c.customer_id
       AND p.payment_status = 'Success'
    GROUP BY c.customer_id
)
SELECT
    customer_id,
    lifetime_spend,
    NTILE(4) OVER (ORDER BY lifetime_spend DESC) AS spend_quartile
FROM customer_spend
ORDER BY spend_quartile, lifetime_spend DESC;


-- Q27: Top three ticket subcategories in each country.
WITH ticket_counts AS (
    SELECT
        c.country,
        t.issue_subcategory,
        COUNT(*) AS ticket_count
    FROM support_tickets AS t
    JOIN customers AS c ON c.customer_id = t.customer_id
    GROUP BY c.country, t.issue_subcategory
)
SELECT country, issue_subcategory, ticket_count
FROM (
    SELECT
        country,
        issue_subcategory,
        ticket_count,
        ROW_NUMBER() OVER (
            PARTITION BY country
            ORDER BY ticket_count DESC, issue_subcategory
        ) AS row_num
    FROM ticket_counts
) AS ranked_tickets
WHERE row_num <= 3
ORDER BY country, row_num;


-- Q28: Identify customers with 2+ failed payments in the last 90 days who are high churn risk.
-- No predicted-risk flag exists; churned = TRUE is used only as a historical proxy.
SELECT
    p.customer_id,
    COUNT(*) AS failed_payment_count,
    MAX(plan.plan_name) AS current_plan
FROM payments AS p
JOIN churn_labels AS cl ON cl.customer_id = p.customer_id
LEFT JOIN subscriptions AS s
    ON s.customer_id = p.customer_id
   AND s.subscription_status = 'Active'
LEFT JOIN subscription_plans AS plan ON plan.plan_id = s.plan_id
WHERE p.payment_status = 'Failed'
  AND p.payment_date >= CURRENT_DATE - INTERVAL '90 days'
  AND p.payment_date <= CURRENT_DATE
  AND cl.churned = TRUE
GROUP BY p.customer_id
HAVING COUNT(*) >= 2
ORDER BY failed_payment_count DESC;


-- Q29: Compare average viewing minutes in the 30 days before and after the latest price change.
-- A price change is inferred when monthly_price differs from the customer's prior subscription.
WITH price_history AS (
    SELECT
        customer_id,
        subscription_start_date AS change_date,
        monthly_price,
        LAG(monthly_price) OVER (
            PARTITION BY customer_id
            ORDER BY subscription_start_date, subscription_id
        ) AS previous_price
    FROM subscriptions
), price_changes AS (
    SELECT
        customer_id,
        change_date,
        monthly_price,
        previous_price,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY change_date DESC
        ) AS latest_change
    FROM price_history
    WHERE previous_price IS NOT NULL
      AND monthly_price <> previous_price
), latest_price_changes AS (
    SELECT customer_id, change_date
    FROM price_changes
    WHERE latest_change = 1
)
SELECT
    c.customer_id,
    c.change_date,
    ROUND(AVG(v.watch_duration_minutes) FILTER (
        WHERE v.viewing_date >= c.change_date - 30
          AND v.viewing_date < c.change_date
    ), 2) AS average_minutes_before,
    ROUND(AVG(v.watch_duration_minutes) FILTER (
        WHERE v.viewing_date >= c.change_date
          AND v.viewing_date < c.change_date + 30
    ), 2) AS average_minutes_after,
    ROUND(100.0 * (
        AVG(v.watch_duration_minutes) FILTER (
            WHERE v.viewing_date >= c.change_date
              AND v.viewing_date < c.change_date + 30
        )
        - AVG(v.watch_duration_minutes) FILTER (
            WHERE v.viewing_date >= c.change_date - 30
              AND v.viewing_date < c.change_date
        )
    ) / NULLIF(AVG(v.watch_duration_minutes) FILTER (
        WHERE v.viewing_date >= c.change_date - 30
          AND v.viewing_date < c.change_date
    ), 0), 2) AS engagement_change_percent
FROM latest_price_changes AS c
LEFT JOIN viewing_activity AS v
    ON v.customer_id = c.customer_id
   AND v.viewing_date >= c.change_date - 30
   AND v.viewing_date < c.change_date + 30
GROUP BY c.customer_id, c.change_date
ORDER BY c.customer_id;


-- Q30: Country totals, churn rate, churned-customer lifetime value, and top churn reason.
WITH customer_value AS (
    SELECT
        cl.customer_id,
        cl.churn_date,
        cl.churn_reason,
        cl.churned,
        COALESCE(SUM(p.amount), 0) AS lifetime_value
    FROM churn_labels AS cl
    LEFT JOIN payments AS p
        ON p.customer_id = cl.customer_id
       AND p.payment_status = 'Success'
       AND p.payment_date <= COALESCE(cl.churn_date, CURRENT_DATE)
    GROUP BY cl.customer_id, cl.churn_date, cl.churn_reason, cl.churned
), country_totals AS (
    SELECT
        c.country,
        COUNT(*) AS total_customers,
        COUNT(*) FILTER (WHERE v.churned = TRUE) AS churned_customers,
        AVG(v.lifetime_value) FILTER (WHERE v.churned = TRUE) AS average_churned_lifetime_value
    FROM customers AS c
    LEFT JOIN customer_value AS v ON v.customer_id = c.customer_id
    GROUP BY c.country
), reason_ranks AS (
    SELECT
        c.country,
        v.churn_reason,
        COUNT(*) AS reason_count,
        ROW_NUMBER() OVER (
            PARTITION BY c.country
            ORDER BY COUNT(*) DESC, v.churn_reason
        ) AS reason_rank
    FROM customers AS c
    JOIN customer_value AS v ON v.customer_id = c.customer_id
    WHERE v.churned = TRUE
    GROUP BY c.country, v.churn_reason
)
SELECT
    t.country,
    t.total_customers,
    t.churned_customers,
    ROUND(100.0 * t.churned_customers / NULLIF(t.total_customers, 0), 2) AS churn_rate_percent,
    ROUND(t.average_churned_lifetime_value, 2) AS average_churned_lifetime_value,
    r.churn_reason AS top_churn_reason
FROM country_totals AS t
LEFT JOIN reason_ranks AS r
    ON r.country = t.country
   AND r.reason_rank = 1
ORDER BY t.country;


-- Q31: Top 50 active customers by estimated at-risk monthly revenue.
-- Inactivity, payment failures, and ticket count are scaled 0-100 and weighted equally.
WITH active_customers AS (
    SELECT s.customer_id, p.plan_name, s.monthly_price
    FROM subscriptions AS s
    JOIN subscription_plans AS p ON p.plan_id = s.plan_id
    WHERE s.subscription_status = 'Active'
), activity AS (
    SELECT customer_id, MAX(viewing_date) AS last_viewing_date
    FROM viewing_activity
    GROUP BY customer_id
), payment_totals AS (
    SELECT
        customer_id,
        COUNT(*) AS payment_count,
        COUNT(*) FILTER (WHERE payment_status = 'Failed') AS failed_payment_count
    FROM payments
    GROUP BY customer_id
), ticket_totals AS (
    SELECT customer_id, COUNT(*) AS ticket_count
    FROM support_tickets
    GROUP BY customer_id
), risk_scores AS (
    SELECT
        c.customer_id,
        c.plan_name,
        c.monthly_price,
        (
            LEAST(COALESCE(CURRENT_DATE - a.last_viewing_date, 90), 90) * 100.0 / 90
            + COALESCE(100.0 * p.failed_payment_count / NULLIF(p.payment_count, 0), 0)
            + LEAST(COALESCE(t.ticket_count, 0), 10) * 10
        ) / 3 AS risk_score
    FROM active_customers AS c
    LEFT JOIN activity AS a ON a.customer_id = c.customer_id
    LEFT JOIN payment_totals AS p ON p.customer_id = c.customer_id
    LEFT JOIN ticket_totals AS t ON t.customer_id = c.customer_id
)
SELECT
    customer_id,
    plan_name,
    ROUND(risk_score, 2) AS risk_score,
    ROUND(risk_score * monthly_price / 100, 2) AS at_risk_monthly_revenue
FROM risk_scores
ORDER BY at_risk_monthly_revenue DESC
LIMIT 50;


-- Q32: Top five complaints per country in the most recent completed calendar quarter.
WITH complaint_counts AS (
    SELECT
        c.country,
        t.issue_subcategory,
        COUNT(*) AS ticket_count,
        AVG(t.resolution_time_hours) AS average_resolution_hours,
        AVG(t.customer_satisfaction_score) AS average_satisfaction
    FROM support_tickets AS t
    JOIN customers AS c ON c.customer_id = t.customer_id
    WHERE t.ticket_date >= DATE_TRUNC('quarter', CURRENT_DATE) - INTERVAL '3 months'
      AND t.ticket_date < DATE_TRUNC('quarter', CURRENT_DATE)
    GROUP BY c.country, t.issue_subcategory
)
SELECT country, issue_subcategory, ticket_count,
       ROUND(average_resolution_hours, 2) AS average_resolution_hours,
       ROUND(average_satisfaction, 2) AS average_satisfaction
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY country
               ORDER BY ticket_count DESC, issue_subcategory
           ) AS row_num
    FROM complaint_counts
) AS ranked_complaints
WHERE row_num <= 5
ORDER BY country, row_num;


-- Q33: Churned top-quartile lifetime-value customers and their last viewing engagement before churn.
WITH customer_values AS (
    SELECT
        cl.customer_id,
        cl.churn_date,
        cl.churn_reason,
        COALESCE(SUM(p.amount), 0) AS lifetime_value
    FROM churn_labels AS cl
    LEFT JOIN payments AS p
        ON p.customer_id = cl.customer_id
       AND p.payment_status = 'Success'
       AND p.payment_date <= cl.churn_date
    WHERE cl.churned = TRUE
    GROUP BY cl.customer_id, cl.churn_date, cl.churn_reason
), ranked_customers AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY lifetime_value DESC) AS value_quartile
    FROM customer_values
), last_viewing AS (
    SELECT
        v.customer_id,
        v.watch_duration_minutes,
        ROW_NUMBER() OVER (
            PARTITION BY v.customer_id
            ORDER BY v.viewing_date DESC, v.viewing_id DESC
        ) AS row_num
    FROM viewing_activity AS v
    JOIN churn_labels AS cl ON cl.customer_id = v.customer_id
    WHERE cl.churned = TRUE
      AND v.viewing_date <= cl.churn_date
)
SELECT
    c.customer_id,
    c.churn_reason,
    c.lifetime_value,
    v.watch_duration_minutes AS last_session_minutes
FROM ranked_customers AS c
LEFT JOIN last_viewing AS v
    ON v.customer_id = c.customer_id
   AND v.row_num = 1
WHERE c.value_quartile = 1
ORDER BY c.lifetime_value DESC;


-- Q34: Most common plan migration and churn rates for upgrades versus downgrades.
WITH migrations AS (
    SELECT
        s.customer_id,
        old_plan.plan_name AS from_plan,
        new_plan.plan_name AS to_plan,
        CASE
            WHEN s.monthly_price > s.old_price THEN 'Upgrade'
            WHEN s.monthly_price < s.old_price THEN 'Downgrade'
            ELSE 'Same price'
        END AS migration_type,
        cl.churned
    FROM (
        SELECT *,
               LAG(plan_id) OVER (
                   PARTITION BY customer_id
                   ORDER BY subscription_start_date, subscription_id
               ) AS old_plan_id,
               LAG(monthly_price) OVER (
                   PARTITION BY customer_id
                   ORDER BY subscription_start_date, subscription_id
               ) AS old_price
        FROM subscriptions
    ) AS s
    JOIN subscription_plans AS old_plan ON old_plan.plan_id = s.old_plan_id
    JOIN subscription_plans AS new_plan ON new_plan.plan_id = s.plan_id
    LEFT JOIN churn_labels AS cl ON cl.customer_id = s.customer_id
    WHERE s.old_plan_id IS NOT NULL
      AND s.old_plan_id <> s.plan_id
), migration_counts AS (
    SELECT from_plan, to_plan, COUNT(*) AS migration_count
    FROM migrations
    GROUP BY from_plan, to_plan
), direction_churn AS (
    SELECT
        migration_type,
        COUNT(DISTINCT customer_id) AS customers,
        COUNT(DISTINCT customer_id) FILTER (WHERE churned = TRUE) AS churned_customers
    FROM migrations
    GROUP BY migration_type
), most_common AS (
    SELECT from_plan, to_plan, migration_count
    FROM migration_counts
    ORDER BY migration_count DESC, from_plan, to_plan
    LIMIT 1
)
SELECT
    m.from_plan || ' → ' || m.to_plan AS most_common_migration,
    m.migration_count,
    d.migration_type,
    ROUND(100.0 * d.churned_customers / NULLIF(d.customers, 0), 2) AS churn_rate_percent
FROM most_common AS m
CROSS JOIN direction_churn AS d
ORDER BY d.migration_type;


-- Q35: Monthly WAU, MAU, and stickiness for the six latest months in viewing data.
-- WAU is customers who watched during the last seven days of each month.
SELECT
    m.month::date AS month,
    COUNT(DISTINCT v.customer_id) FILTER (
        WHERE v.viewing_date >= m.month + INTERVAL '1 month' - INTERVAL '7 days'
    ) AS weekly_active_users,
    COUNT(DISTINCT v.customer_id) AS monthly_active_users,
    ROUND(
        100.0 * COUNT(DISTINCT v.customer_id) FILTER (
            WHERE v.viewing_date >= m.month + INTERVAL '1 month' - INTERVAL '7 days'
        ) / NULLIF(COUNT(DISTINCT v.customer_id), 0),
        2
    ) AS stickiness_percent
FROM GENERATE_SERIES(
    DATE_TRUNC('month', (SELECT MAX(viewing_date) FROM viewing_activity)) - INTERVAL '5 months',
    DATE_TRUNC('month', (SELECT MAX(viewing_date) FROM viewing_activity)),
    INTERVAL '1 month'
) AS m(month)
LEFT JOIN viewing_activity AS v
    ON v.viewing_date >= m.month
   AND v.viewing_date < m.month + INTERVAL '1 month'
GROUP BY m.month
ORDER BY m.month;


-- Q36: Negative feedback within 14 days after a failed payment or low-rated ticket.
SELECT DISTINCT
    f.customer_id,
    f.feedback_id,
    f.feedback_date
FROM customer_feedback AS f
WHERE f.sentiment_label = 'Negative'
  AND (
      EXISTS (
          SELECT 1
          FROM payments AS p
          WHERE p.customer_id = f.customer_id
            AND p.payment_status = 'Failed'
            AND f.feedback_date BETWEEN p.payment_date AND p.payment_date + 14
      )
      OR EXISTS (
          SELECT 1
          FROM support_tickets AS t
          WHERE t.customer_id = f.customer_id
            AND t.customer_satisfaction_score <= 2
            AND f.feedback_date BETWEEN t.ticket_date AND t.ticket_date + 14
      )
  )
ORDER BY f.feedback_date, f.customer_id;


-- Q37: Health risk score (0-100) for active customers using viewing, payments, support, tenure, and plan.
-- The four normalized risk factors are weighted equally; tenure is measured from registration.
WITH active_customers AS (
    SELECT s.customer_id, p.plan_name, c.registration_date
    FROM subscriptions AS s
    JOIN subscription_plans AS p ON p.plan_id = s.plan_id
    JOIN customers AS c ON c.customer_id = s.customer_id
    WHERE s.subscription_status = 'Active'
), viewing AS (
    SELECT customer_id, MAX(viewing_date) AS last_viewing_date
    FROM viewing_activity
    GROUP BY customer_id
), payment_stats AS (
    SELECT
        customer_id,
        COUNT(*) AS payment_count,
        COUNT(*) FILTER (WHERE payment_status = 'Failed') AS failed_payment_count
    FROM payments
    GROUP BY customer_id
), support AS (
    SELECT customer_id, AVG(customer_satisfaction_score) AS average_satisfaction
    FROM support_tickets
    GROUP BY customer_id
), customer_scores AS (
    SELECT
        c.customer_id,
        c.plan_name,
        CURRENT_DATE - c.registration_date AS tenure_days,
        COALESCE(CURRENT_DATE - v.last_viewing_date, 90) AS days_since_last_viewing,
        COALESCE(100.0 * p.failed_payment_count / NULLIF(p.payment_count, 0), 0) AS failed_payment_rate,
        s.average_satisfaction
    FROM active_customers AS c
    LEFT JOIN viewing AS v ON v.customer_id = c.customer_id
    LEFT JOIN payment_stats AS p ON p.customer_id = c.customer_id
    LEFT JOIN support AS s ON s.customer_id = c.customer_id
)
SELECT
    customer_id,
    plan_name,
    ROUND((
        LEAST(days_since_last_viewing, 90) * 100.0 / 90
        + failed_payment_rate
        + COALESCE((5 - average_satisfaction) * 25, 50)
        + GREATEST(0, 100 - LEAST(tenure_days, 365) * 100.0 / 365)
    ) / 4, 2) AS health_risk_score,
    RANK() OVER (ORDER BY (
        LEAST(days_since_last_viewing, 90) * 100.0 / 90
        + failed_payment_rate
        + COALESCE((5 - average_satisfaction) * 25, 50)
        + GREATEST(0, 100 - LEAST(tenure_days, 365) * 100.0 / 365)
    ) DESC) AS risk_rank
FROM customer_scores
ORDER BY risk_rank;
