-- ════════════════════════════════════════
-- PHASE 2
-- DASHBOARD ARCHITECTURE
-- RUN AFTER PHASE 1
-- ════════════════════════════════════════

-- DASHBOARD TABLES

CREATE TABLE IF NOT EXISTS admin_dashboards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE NOT NULL,
  name text NOT NULL,
  description text,
  icon text,
  category text,
  is_system boolean DEFAULT false,
  created_by uuid REFERENCES admin_users(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS admin_dashboard_layouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  role admin_role NOT NULL,
  dashboard_slug text NOT NULL,
  layout_json jsonb NOT NULL,
  mobile_layout_json jsonb,
  tablet_layout_json jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(user_id, dashboard_slug)
);

CREATE TABLE IF NOT EXISTS admin_dashboard_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  dashboard_slug text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, dashboard_slug)
);

CREATE TABLE IF NOT EXISTS admin_widget_preferences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  widget_id text NOT NULL,
  preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(user_id, widget_id)
);

-- INDEXES

CREATE INDEX IF NOT EXISTS admin_dashboard_layouts_user_idx
ON admin_dashboard_layouts(user_id);

CREATE INDEX IF NOT EXISTS admin_dashboard_layouts_dashboard_idx
ON admin_dashboard_layouts(dashboard_slug);

CREATE INDEX IF NOT EXISTS admin_dashboard_favorites_user_idx
ON admin_dashboard_favorites(user_id);

CREATE INDEX IF NOT EXISTS admin_widget_preferences_user_idx
ON admin_widget_preferences(user_id);

-- ROLE DEFAULT PERMISSIONS

INSERT INTO role_permissions(role, permission) VALUES

('super_admin', 'dashboard.read'),
('super_admin', 'dashboard.write'),
('super_admin', 'dashboard.customize'),

('super_admin', 'projects.read'),
('super_admin', 'projects.create'),
('super_admin', 'projects.update'),
('super_admin', 'projects.delete'),
('super_admin', 'projects.publish'),
('super_admin', 'projects.archive'),
('super_admin', 'projects.analytics'),
('super_admin', 'projects.featured'),

('super_admin', 'revenue.read'),

('super_admin', 'sessions.read'),
('super_admin', 'sessions.kill'),

('super_admin', 'audit.read'),

('super_admin', 'monitoring.read'),

('super_admin', 'security.read'),

('super_admin', 'moderation.read'),
('super_admin', 'moderation.write'),

('super_admin', 'mentors.read'),
('super_admin', 'mentors.verify'),

('super_admin', 'analytics.read'),

('super_admin', 'widgets.customize'),

('super_admin', 'feature_flags.read'),
('super_admin', 'feature_flags.write'),

-- ADMIN

('admin', 'dashboard.read'),
('admin', 'dashboard.customize'),

('admin', 'projects.read'),
('admin', 'projects.create'),
('admin', 'projects.update'),
('admin', 'projects.publish'),
('admin', 'projects.archive'),
('admin', 'projects.analytics'),

('admin', 'sessions.read'),

('admin', 'audit.read'),

('admin', 'moderation.read'),
('admin', 'moderation.write'),

('admin', 'mentors.read'),
('admin', 'mentors.verify'),

('admin', 'analytics.read'),

('admin', 'widgets.customize'),

-- DEVELOPER

('developer', 'dashboard.read'),

('developer', 'projects.read'),
('developer', 'projects.analytics'),

('developer', 'sessions.read'),

('developer', 'audit.read'),

('developer', 'monitoring.read'),

('developer', 'analytics.read'),

('developer', 'feature_flags.read'),
('developer', 'feature_flags.write'),

-- SUPPORT

('support', 'dashboard.read'),

('support', 'projects.read'),

('support', 'sessions.read'),

('support', 'moderation.read'),

('support', 'mentors.read')

ON CONFLICT DO NOTHING;

-- EXISTING USER PROJECT ACCESS

INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, perm::admin_permission, true, null
FROM admin_users
CROSS JOIN (
  VALUES
    ('projects.read'),
    ('projects.create'),
    ('projects.update'),
    ('projects.delete'),
    ('projects.publish'),
    ('projects.archive'),
    ('projects.analytics'),
    ('projects.featured')
) AS p(perm)
WHERE role = 'super_admin'
ON CONFLICT (user_id, permission)
DO UPDATE SET granted = true;

INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, perm::admin_permission, true, null
FROM admin_users
CROSS JOIN (
  VALUES
    ('projects.read'),
    ('projects.create'),
    ('projects.update'),
    ('projects.publish'),
    ('projects.archive'),
    ('projects.analytics')
) AS p(perm)
WHERE role = 'admin'
ON CONFLICT (user_id, permission)
DO UPDATE SET granted = true;

INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, perm::admin_permission, true, null
FROM admin_users
CROSS JOIN (
  VALUES
    ('projects.read'),
    ('projects.analytics')
) AS p(perm)
WHERE role = 'developer'
ON CONFLICT (user_id, permission)
DO UPDATE SET granted = true;

INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, 'projects.read'::admin_permission, true, null
FROM admin_users
WHERE role = 'support'
ON CONFLICT (user_id, permission)
DO UPDATE SET granted = true;