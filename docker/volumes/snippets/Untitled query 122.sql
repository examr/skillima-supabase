WITH columns AS (
    SELECT
        c.table_schema,
        c.table_name,
        c.column_name,
        c.data_type,
        c.udt_name,
        c.is_nullable,
        c.column_default,
        c.ordinal_position
    FROM information_schema.columns c
    WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema')
),

primary_keys AS (
    SELECT
        tc.table_schema,
        tc.table_name,
        kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
    WHERE tc.constraint_type = 'PRIMARY KEY'
),

foreign_keys AS (
    SELECT
        tc.table_schema,
        tc.table_name,
        kcu.column_name,
        ccu.table_name AS foreign_table_name,
        ccu.column_name AS foreign_column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.constraint_column_usage ccu
        ON ccu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
),

enums AS (
    SELECT
        t.typname AS enum_name,
        array_agg(e.enumlabel ORDER BY e.enumsortorder) AS enum_values
    FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    GROUP BY t.typname
),

rls AS (
    SELECT
        schemaname,
        tablename,
        rowsecurity
    FROM pg_tables
),

policies AS (
    SELECT
        schemaname,
        tablename,
        policyname,
        permissive,
        roles,
        cmd,
        qual,
        with_check
    FROM pg_policies
)

SELECT jsonb_pretty(
    jsonb_agg(
        jsonb_build_object(
            'schema', c.table_schema,
            'table', c.table_name,
            'column', c.column_name,
            'type', c.data_type,
            'nullable', c.is_nullable,
            'default', c.column_default,

            'primary_key',
                EXISTS (
                    SELECT 1
                    FROM primary_keys pk
                    WHERE pk.table_schema = c.table_schema
                      AND pk.table_name = c.table_name
                      AND pk.column_name = c.column_name
                ),

            'foreign_key',
                (
                    SELECT jsonb_build_object(
                        'table', fk.foreign_table_name,
                        'column', fk.foreign_column_name
                    )
                    FROM foreign_keys fk
                    WHERE fk.table_schema = c.table_schema
                      AND fk.table_name = c.table_name
                      AND fk.column_name = c.column_name
                    LIMIT 1
                ),

            'enum_values',
                (
                    SELECT enum_values
                    FROM enums e
                    WHERE e.enum_name = c.udt_name
                    LIMIT 1
                ),

            'rls_enabled',
                (
                    SELECT r.rowsecurity
                    FROM rls r
                    WHERE r.schemaname = c.table_schema
                      AND r.tablename = c.table_name
                    LIMIT 1
                ),

            'policies',
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'name', p.policyname,
                            'command', p.cmd,
                            'roles', p.roles,
                            'using', p.qual,
                            'with_check', p.with_check
                        )
                    )
                    FROM policies p
                    WHERE p.schemaname = c.table_schema
                      AND p.tablename = c.table_name
                )
        )
        ORDER BY c.table_schema, c.table_name, c.ordinal_position
    )
) AS complete_schema
FROM columns c;