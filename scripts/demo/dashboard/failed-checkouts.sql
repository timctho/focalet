SELECT minute,
       SUM(outcome = 'failed') AS failed,
       COUNT(*) AS total
FROM checkouts
GROUP BY minute
ORDER BY minute;
