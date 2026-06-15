-- 1. Enable the pg_cron and pg_net extensions
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Safely unschedule existing jobs only if they exist
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notion-queue-worker') THEN
    PERFORM cron.unschedule('notion-queue-worker');
  END IF;
  
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notion-poll') THEN
    PERFORM cron.unschedule('notion-poll');
  END IF;
END $$;

-- 3. Schedule the Queue Worker to run every 1 minute
SELECT cron.schedule(
  'notion-queue-worker',
  '* * * * *', -- cron syntax for every minute
  $$
  SELECT net.http_post(
    url := 'https://admin.skillima.com/api/notion/queue/worker',
    headers := '{"Authorization": "Bearer a203b4ce23ed25b9138ccbdc3654bbe3e306f04bfaa3609f3134fcb85fb392f0", "Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb
  );
  $$
);

-- 4. Schedule the Poller fallback to run every 5 minutes
SELECT cron.schedule(
  'notion-poll',
  '*/5 * * * *', -- cron syntax for every 5 minutes
  $$
  SELECT net.http_post(
    url := 'https://admin.skillima.com/api/notion/poll',
    headers := '{"Authorization": "Bearer a203b4ce23ed25b9138ccbdc3654bbe3e306f04bfaa3609f3134fcb85fb392f0", "Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb
  );
  $$
);
