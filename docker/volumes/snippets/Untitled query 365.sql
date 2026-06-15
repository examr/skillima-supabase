-- v5.1 default layouts migration
-- Insert default layouts for new dashboards for all existing admin users in admin.admin_dashboard_layouts

DO $$
DECLARE
    u RECORD;
BEGIN
    FOR u IN SELECT id, role FROM admin.admin_users LOOP
        -- admin-projects (for admin and super_admin roles)
        IF u.role IN ('admin', 'super_admin') THEN
            INSERT INTO admin.admin_dashboard_layouts (user_id, role, dashboard_slug, layout_json, tablet_layout_json, mobile_layout_json)
            VALUES (
                u.id,
                u.role,
                'admin-projects',
                '[{"widgetId": "widget_admin_projects_list", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_admin_projects_list", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_admin_projects_list", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb
            ) ON CONFLICT (user_id, dashboard_slug) DO UPDATE
            SET layout_json = EXCLUDED.layout_json,
                tablet_layout_json = EXCLUDED.tablet_layout_json,
                mobile_layout_json = EXCLUDED.mobile_layout_json;
        END IF;

        -- project-pool (for admin and super_admin roles)
        IF u.role IN ('admin', 'super_admin') THEN
            INSERT INTO admin.admin_dashboard_layouts (user_id, role, dashboard_slug, layout_json, tablet_layout_json, mobile_layout_json)
            VALUES (
                u.id,
                u.role,
                'project-pool',
                '[{"widgetId": "widget_project_pool_stats", "x": 0, "y": 0, "w": 12, "h": 3}, {"widgetId": "widget_project_pool_table", "x": 0, "y": 3, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_project_pool_stats", "x": 0, "y": 0, "w": 12, "h": 3}, {"widgetId": "widget_project_pool_table", "x": 0, "y": 3, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_project_pool_stats", "x": 0, "y": 0, "w": 12, "h": 3}, {"widgetId": "widget_project_pool_table", "x": 0, "y": 3, "w": 12, "h": 6}]'::jsonb
            ) ON CONFLICT (user_id, dashboard_slug) DO UPDATE
            SET layout_json = EXCLUDED.layout_json,
                tablet_layout_json = EXCLUDED.tablet_layout_json,
                mobile_layout_json = EXCLUDED.mobile_layout_json;
        END IF;

        -- platform-config (for admin, super_admin, developer roles)
        IF u.role IN ('admin', 'super_admin', 'developer') THEN
            INSERT INTO admin.admin_dashboard_layouts (user_id, role, dashboard_slug, layout_json, tablet_layout_json, mobile_layout_json)
            VALUES (
                u.id,
                u.role,
                'platform-config',
                '[{"widgetId": "widget_platform_config_editor", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_platform_config_editor", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_platform_config_editor", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb
            ) ON CONFLICT (user_id, dashboard_slug) DO UPDATE
            SET layout_json = EXCLUDED.layout_json,
                tablet_layout_json = EXCLUDED.tablet_layout_json,
                mobile_layout_json = EXCLUDED.mobile_layout_json;
        END IF;

        -- permissions (super_admin only)
        IF u.role = 'super_admin' THEN
            INSERT INTO admin.admin_dashboard_layouts (user_id, role, dashboard_slug, layout_json, tablet_layout_json, mobile_layout_json)
            VALUES (
                u.id,
                u.role,
                'permissions',
                '[{"widgetId": "widget_super_admin_permissions", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_super_admin_permissions", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb,
                '[{"widgetId": "widget_super_admin_permissions", "x": 0, "y": 0, "w": 12, "h": 6}]'::jsonb
            ) ON CONFLICT (user_id, dashboard_slug) DO UPDATE
            SET layout_json = EXCLUDED.layout_json,
                tablet_layout_json = EXCLUDED.tablet_layout_json,
                mobile_layout_json = EXCLUDED.mobile_layout_json;
        END IF;

    END LOOP;
END;
$$;
