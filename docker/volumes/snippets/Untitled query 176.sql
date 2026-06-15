-- ════════════════════════════════════════
-- PHASE 1
-- ENUM EXTENSIONS
-- RUN THIS FIRST
-- ════════════════════════════════════════

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'dashboard.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'dashboard.write';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'dashboard.customize';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.create';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.update';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.delete';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.publish';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.archive';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.analytics';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'projects.featured';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'revenue.read';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'sessions.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'sessions.kill';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'audit.read';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'monitoring.read';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'security.read';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'moderation.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'moderation.write';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'mentors.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'mentors.verify';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'analytics.read';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'widgets.customize';

ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'feature_flags.read';
ALTER TYPE admin_permission ADD VALUE IF NOT EXISTS 'feature_flags.write';

-- AUDIT ACTIONS

ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'dashboard.create';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'dashboard.update';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'dashboard.delete';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'dashboard.reset';

ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'widget.add';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'widget.remove';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'widget.resize';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'widget.move';

ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'dashboard.favorite';

COMMIT;