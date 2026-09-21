WITH base_checkouts AS (
    SELECT id, minute, outcome
    FROM checkouts
),
enriched AS (
    SELECT
        c.id,
        c.minute,
        c.outcome,
        e.event_type
    FROM base_checkouts AS c
    LEFT JOIN checkout_events AS e ON e.checkout_id = c.id
)
SELECT minute,
       ROUND(100.0 * SUM(outcome = 'failed')
             / COUNT(*), 2) AS error_rate
FROM enriched
GROUP BY minute
ORDER BY minute;
