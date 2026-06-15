-- Returns all user-created tables in the public schema
create or replace function get_public_tables()
returns table (table_name text)
language sql
security definer
set search_path = public
as $$
  select t.table_name::text
  from information_schema.tables t
  where t.table_schema = 'public'
    and t.table_type = 'BASE TABLE'
  order by t.table_name;
$$;

-- Returns column metadata for a table in the public schema
create or replace function get_table_schema(p_table_name text)
returns table (
  column_name text,
  data_type text,
  is_nullable text,
  column_default text,
  character_maximum_length int
)
language sql
security definer
set search_path = public
as $$
  select
    c.column_name::text,
    c.data_type::text,
    c.is_nullable::text,
    c.column_default::text,
    c.character_maximum_length
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = p_table_name
  order by c.ordinal_position;
$$;

grant execute on function get_public_tables() to service_role;
grant execute on function get_table_schema(text) to service_role;