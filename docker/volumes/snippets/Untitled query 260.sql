-- ── Email Templates Table (admin schema) ──────────────────────────────────────
-- Stores fully customizable templates for system emails (e.g. mentor approval, rejection).
-- Access restricted to service_role and Supabase superusers.

CREATE TABLE IF NOT EXISTS admin.email_templates (
  id               text PRIMARY KEY,               -- Unique identifier: 'mentor_approved', 'mentor_rejected'
  name             text NOT NULL,                  -- Human-readable name
  subject          text NOT NULL,                  -- Email subject line
  body_html        text NOT NULL,                  -- Custom HTML body with double curly placeholders (e.g. {{mentor_name}})
  description      text,                           -- Admin tool explanation
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by_name  text,                           -- Name of the last admin editor
  updated_by_email text                            -- Email of the last admin editor
);

COMMENT ON TABLE admin.email_templates IS
  'Customizable email templates with variables placeholders. Stored in admin schema.';

-- Revoke all public access — only service_role (ops dashboard) can read/write
REVOKE ALL ON admin.email_templates FROM anon, authenticated;

-- Insert default templates
INSERT INTO admin.email_templates (id, name, subject, body_html, description)
VALUES 
(
  'mentor_approved',
  'Mentor Approved Email',
  'Congratulations! Your Skillima Mentor Application is Approved',
  '<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Skillima Mentor Approved</title>
  </head>
  <body style="font-family: ''Inter'', -apple-system, BlinkMacSystemFont, sans-serif; background-color: #f4f5f7; padding: 40px 0; margin: 0;">
    <div style="max-width: 540px; margin: 0 auto; background-color: #ffffff; border-radius: 16px; border: 1px solid #e2e5ec; overflow: hidden; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.03);">
      <div style="background-color: #15181e; padding: 28px; text-align: center; border-bottom: 1px solid #e2e5ec;">
        <h1 style="color: #ffffff; margin: 0; font-size: 20px; font-weight: 700; letter-spacing: -0.02em;">Skillima Operations</h1>
      </div>
      <div style="padding: 32px; color: #111317;">
        <h2 style="color: #8b5cf6; margin: 0 0 16px; font-size: 18px; font-weight: 700;">Application Approved!</h2>
        <p style="font-size: 14px; line-height: 1.5; color: #111317; margin: 0 0 16px;">Hello {{mentor_name}},</p>
        <p style="font-size: 14px; line-height: 1.5; color: #374151; margin: 0 0 20px;">We are pleased to inform you that your application to become an expert mentor on Skillima has been approved! Our team has verified your credentials and experience.</p>
        
        <p style="font-size: 14px; line-height: 1.5; color: #374151; margin: 0 0 24px;">You can now log in to the platform, complete your profile, publish projects, and start accepting students.</p>
        
        {{#if note}}
        <div style="background-color: #f8fafc; border-left: 4px solid #8b5cf6; border-radius: 8px; padding: 16px; margin: 0 0 24px; border-top: 1px solid #f1f5f9; border-right: 1px solid #f1f5f9; border-bottom: 1px solid #f1f5f9;">
          <p style="font-size: 12px; font-weight: 700; color: #1f2937; margin: 0 0 6px; text-transform: uppercase; letter-spacing: 0.05em;">Reviewer Note:</p>
          <p style="font-size: 13px; line-height: 1.5; color: #4b5563; margin: 0;">{{note}}</p>
        </div>
        {{/if}}
        
        <div style="text-align: center; margin: 32px 0 20px;">
          <a href="{{app_url}}/login" style="background-color: #15181e; color: #fafafa; padding: 12px 24px; border-radius: 10px; text-decoration: none; display: inline-block; font-weight: 600; font-size: 13px; transition: background-color 100ms ease-out;">
            Go to Platform Login &rarr;
          </a>
        </div>
        
        <p style="color: #9ca3af; font-size: 12px; margin-top: 32px; border-top: 1px solid #e2e5ec; padding-top: 20px; line-height: 1.5; text-align: center;">
          Thank you for joining the Skillima community.
        </p>
      </div>
    </div>
  </body>
</html>',
  'Sent when a mentor application is approved'
),
(
  'mentor_rejected',
  'Mentor Rejected Email',
  'Skillima Mentor Application Status Update',
  '<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Skillima Mentor Application Status</title>
  </head>
  <body style="font-family: ''Inter'', -apple-system, BlinkMacSystemFont, sans-serif; background-color: #f4f5f7; padding: 40px 0; margin: 0;">
    <div style="max-width: 540px; margin: 0 auto; background-color: #ffffff; border-radius: 16px; border: 1px solid #e2e5ec; overflow: hidden; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.03);">
      <div style="background-color: #15181e; padding: 28px; text-align: center; border-bottom: 1px solid #e2e5ec;">
        <h1 style="color: #ffffff; margin: 0; font-size: 20px; font-weight: 700; letter-spacing: -0.02em;">Skillima Operations</h1>
      </div>
      <div style="padding: 32px; color: #111317;">
        <h2 style="color: #f43f5e; margin: 0 0 16px; font-size: 18px; font-weight: 700;">Application Update</h2>
        <p style="font-size: 14px; line-height: 1.5; color: #111317; margin: 0 0 16px;">Hello {{mentor_name}},</p>
        <p style="font-size: 14px; line-height: 1.5; color: #374151; margin: 0 0 20px;">Thank you for your interest in becoming a mentor on Skillima. After carefully reviewing your profile and credentials, we regret to inform you that we are unable to approve your application at this time.</p>
        
        {{#if note}}
        <div style="background-color: #fff5f5; border-left: 4px solid #f43f5e; border-radius: 8px; padding: 16px; margin: 0 0 24px; border-top: 1px solid #fee2e2; border-right: 1px solid #fee2e2; border-bottom: 1px solid #fee2e2;">
          <p style="font-size: 12px; font-weight: 700; color: #991b1b; margin: 0 0 6px; text-transform: uppercase; letter-spacing: 0.05em;">Feedback / Reason:</p>
          <p style="font-size: 13px; line-height: 1.5; color: #b91c1c; margin: 0;">{{note}}</p>
        </div>
        {{/if}}
        
        <p style="font-size: 14px; line-height: 1.5; color: #374151; margin: 0 0 24px;">You can review our guidelines, update your experience or projects, and re-apply in the future.</p>
        
        <p style="color: #9ca3af; font-size: 12px; margin-top: 32px; border-top: 1px solid #e2e5ec; padding-top: 20px; line-height: 1.5; text-align: center;">
          If you have any questions or would like to request further clarification, please reply directly to this email.
        </p>
      </div>
    </div>
  </body>
</html>',
  'Sent when a mentor application is rejected'
)
ON CONFLICT (id) DO NOTHING;
