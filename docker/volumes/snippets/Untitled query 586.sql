UPDATE public.student_profiles
SET github_username = 'gauriishankarrr'   -- real GitHub user
WHERE user_id = '746f914f-e71d-480a-ac52-280e6faa956d';

SELECT github_username, github_username_valid, github_username_error
FROM public.student_profiles
WHERE user_id = '746f914f-e71d-480a-ac52-280e6faa956d';

SELECT req.id, req.url, res.status_code, res.error_msg, res.content, res.created
FROM net.http_request_queue req
LEFT JOIN net._http_response res ON res.id = req.id
ORDER BY req.id DESC
LIMIT 10;

DO $$
DECLARE
  _req_id bigint;
BEGIN
  SELECT net.http_post(
    url     := public.get_edge_function_url('github-username-validate'),
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || public.get_service_role_key()
    ),
    body    := '{"userId":"746f914f-e71d-480a-ac52-280e6faa956d","username":"gauriishankarrr"}'::jsonb
  ) INTO _req_id;
  
  RAISE NOTICE 'Request ID: %', _req_id;
END;
$$;


SELECT net.http_post(
  url     := public.get_edge_function_url('github-username-validate'),
  headers := jsonb_build_object(
    'Content-Type',  'application/json',
    'Authorization', 'Bearer ' || public.get_service_role_key()
  ),
  body    := '{"userId":"746f914f-e71d-480a-ac52-280e6faa956d","username":"examr"}'::jsonb
);


SELECT net.http_post(
  url     := 'http://supabase-edge-functions:9000/github-username-validate',
  headers := jsonb_build_object(
    'Content-Type',  'application/json',
    'Authorization', 'Bearer ' || public.get_service_role_key()
  ),
  body    := '{"userId":"746f914f-e71d-480a-ac52-280e6faa956d","username":"gauriishankarrr"}'::jsonb
);

SELECT id, status_code, error_msg, content
FROM net._http_response
ORDER BY id DESC
LIMIT 3;

SELECT status_code, error_msg, content
FROM net._http_response
ORDER BY id DESC
LIMIT 1;

-- Check if the function can even build the URL and key
DO $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-username-validate');
  _key TEXT := public.get_service_role_key();
BEGIN
  RAISE NOTICE 'URL: %', _url;
  RAISE NOTICE 'Key length: %', length(_key);
END;
$$;


-- Check if pg_net schema is accessible from a trigger context
DO $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://httpbin.org/post',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body    := '{"test": "trigger_test"}'::jsonb
  );
  RAISE NOTICE 'net.http_post called successfully';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'ERROR: % %', SQLSTATE, SQLERRM;
END;
$$;

SELECT id, status_code, content, created
FROM net._http_response
ORDER BY id DESC
LIMIT 3;

SELECT prosrc FROM pg_proc WHERE proname = 'notify_github_username_set';


CREATE OR REPLACE FUNCTION public.notify_github_username_set()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = 'public, net, extensions'
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-username-validate');
  _key TEXT := public.get_service_role_key();
BEGIN
  IF NEW.github_username IS NOT DISTINCT FROM OLD.github_username THEN
    RETURN NEW;
  END IF;

  NEW.github_username_valid := NULL;
  NEW.github_username_error := NULL;

  IF NEW.github_username IS NOT NULL AND trim(NEW.github_username) <> '' THEN
    PERFORM net.http_post(
      url     := _url,
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || _key
      ),
      body    := jsonb_build_object(
        'userId',   NEW.user_id,
        'username', NEW.github_username
      )
    );
  END IF;

  RETURN NEW;
END;
$$;



CREATE OR REPLACE FUNCTION public.get_edge_function_url(fn_name TEXT)
  RETURNS TEXT
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
  SELECT 'http://supabase-edge-functions:9000/' || fn_name;
$$;


SELECT net.http_post(
  url     := public.get_edge_function_url('github-username-validate'),
  headers := jsonb_build_object(
    'Content-Type',  'application/json',
    'Authorization', 'Bearer ' || public.get_service_role_key()
  ),
  body    := '{"userId":"746f914f-e71d-480a-ac52-280e6faa956d","username":"gauriishankarrr"}'::jsonb
) AS request_id;

SELECT status_code, content FROM net._http_response ORDER BY id DESC LIMIT 1;
SELECT status_code, error_msg, content
FROM net._http_response
ORDER BY id DESC
LIMIT 1;


SELECT public.get_edge_function_url('github-username-validate');