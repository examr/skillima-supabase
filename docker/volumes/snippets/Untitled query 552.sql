ALTER PUBLICATION supabase_realtime ADD TABLE admin_notifications;


CREATE OR REPLACE FUNCTION exec_ddl(sql text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  EXECUTE sql;
END;
$$;

REVOKE ALL ON FUNCTION exec_ddl(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION exec_ddl(text) TO service_role;