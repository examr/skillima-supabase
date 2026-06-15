-- Grant all 3 project permissions to every super_admin
INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, perm::admin_permission, true, null
FROM admin_users
CROSS JOIN (VALUES
  ('projects.read'),
  ('projects.create'),
  ('projects.delete')
) AS p(perm)
WHERE role = 'super_admin'
ON CONFLICT (user_id, permission) DO UPDATE SET granted = true;

-- Grant projects.read + projects.create to admins
INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, perm::admin_permission, true, null
FROM admin_users
CROSS JOIN (VALUES
  ('projects.read'),
  ('projects.create')
) AS p(perm)
WHERE role = 'admin'
ON CONFLICT (user_id, permission) DO UPDATE SET granted = true;

-- Grant projects.read only to support/developer
INSERT INTO admin_permissions (user_id, permission, granted, granted_by)
SELECT id, 'projects.read'::admin_permission, true, null
FROM admin_users
WHERE role IN ('support', 'developer')
ON CONFLICT (user_id, permission) DO UPDATE SET granted = true;