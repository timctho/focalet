WITH ranked AS (
  SELECT minute, duration_ms,
         ROW_NUMBER() OVER (PARTITION BY minute ORDER BY duration_ms) AS rank,
         COUNT(*) OVER (PARTITION BY minute) AS sample_count
  FROM requests
  WHERE environment = 'production'
    AND route = '/checkout'
    AND minute >= '14:00' AND minute < '15:00'
)
SELECT minute,
       MAX(CASE WHEN rank = (95 * sample_count + 99) / 100
                THEN duration_ms END) AS p95_ms,
       MAX(sample_count) AS requests
FROM ranked
GROUP BY minute
ORDER BY minute;
