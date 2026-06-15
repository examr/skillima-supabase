-- ================================================================
--  SKILLIMA — Production Supabase / PostgreSQL Schema
--  Version 4.0 | March 2026
--
--  COMPLETE SINGLE-FILE SCHEMA — paste into Supabase SQL Editor and Run.
--  Safe for a FRESH database only. Do NOT run on an existing database.
--
--  WHAT IS IN v4.0 (all v3.0 + all migration changes merged):
--
--  ── v3.0 Base ───────────────────────────────────────────────────
--  [GH-2]  github_repo_status ENUM
--  [GH-3]  student_profiles.github_username (replaces github_linked bool)
--  [GH-4]  project_enrollments: github_repo_name + github_status
--  [GH-5]  stage_progress: github_pr_number + github_branch_name
--  [GH-6]  GitHub-related indexes
--  [GH-7]  initialize_stage_progress: sets github_branch_name = 'stage/N'
--  [GH-8]  complete_project: sets github_status = 'transfer_pending'
--  [GH-9]  prevent_sensitive_enrollment_update trigger
--  17 v2.0 fixes preserved (perf, security, arch, data integrity)
--
--  ── v4.0 Part A: Zero Website Dependency ────────────────────────
--  All GitHub API calls moved entirely to DB triggers → pg_net → Edge Functions.
--  5 new trigger functions + 5 new triggers:
--    notify_github_stage_submit()   → github-stage-submit    Edge Fn
--    notify_github_stage_approve()  → github-stage-approve   Edge Fn
--    notify_github_stage_changes()  → github-stage-changes   Edge Fn
--    notify_github_mentor_added()   → github-mentor-added    Edge Fn
--    notify_github_username_set()   → github-username-validate Edge Fn
--  New columns on student_profiles:
--    github_username_valid boolean   (NULL=pending, true=valid, false=invalid)
--    github_username_error text      (set by Edge Fn on failure)
--
--  ── v4.0 Part B: Team Enrollment Support ────────────────────────
--  New ENUM   team_role ('lead' | 'member')
--  New table  teams         — named student group
--  New table  team_members  — M2M team ↔ profiles
--  project_enrollments: team_id (nullable; NULL = solo)
--  New unique index: (team_id, project_id) prevents team double-enroll
--  New function award_team_stage_points() — awards points to all members
--  Updated  approve_stage()   — team-aware point distribution + notifications
--  Updated  complete_project() — team-aware counters + points + notifications
--  New function is_team_member() — used in RLS
--  Updated  is_enrollment_participant() — includes team members
--  RLS on teams + team_members
--
--  ── ARCHITECTURE RULES (enforced throughout) ────────────────────
--  • SET search_path = '' on EVERY function — prevents schema injection
--  • Fully-qualified object names (public.table, auth.uid()) everywhere
--  • auth.uid() always wrapped as (SELECT auth.uid()) in RLS policies
--  • All money stored as bigint in paise (100 paise = ₹1). No DECIMAL/FLOAT.
--  • All timestamps are timestamptz (UTC). Use now() inside functions.
--  • Soft deletes on posts + comments. Hard deletes everywhere else.
--  • Denormalised counters maintained by AFTER triggers — never COUNT(*).
--  • SECURITY DEFINER on all functions that need elevated privileges.
--  • SECURITY INVOKER only on update_updated_at() (touches caller-owned row).
--  • Every UPDATE RLS policy has an explicit WITH CHECK clause.
--  • (SELECT auth.uid()) in every policy — init-plan caching, not per-row.
-- ================================================================

-- ================================================================
-- 0. EXTENSIONS
-- ================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_bytes(), gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- GIN trigram indexes for ILIKE / similarity
CREATE EXTENSION IF NOT EXISTS "unaccent";  -- accent-insensitive search

-- ================================================================
-- 1. CUSTOM ENUM TYPES
-- ================================================================

-- Identity
CREATE TYPE public.user_role AS ENUM ('student', 'mentor', 'admin');
CREATE TYPE public.user_status AS ENUM ('pending', 'active', 'suspended');
CREATE TYPE public.verification_status AS ENUM ('pending', 'approved', 'rejected');

-- Ranks
CREATE TYPE public.rank_tier_student AS ENUM (
  'novice', 'apprentice', 'journeyman', 'craftsman', 'expert', 'master', 'grandmaster'
);
CREATE TYPE public.rank_tier_mentor AS ENUM (
  'guide', 'instructor', 'sage', 'virtuoso', 'luminary', 'legend'
);

-- Skills
CREATE TYPE public.proficiency_level AS ENUM (
  'beginner', 'intermediate', 'advanced', 'expert'
);

-- Marketplace
CREATE TYPE public.project_difficulty AS ENUM (
  'beginner', 'intermediate', 'advanced', 'expert'
);
CREATE TYPE public.project_status AS ENUM ('draft', 'published', 'archived');

-- Mentorship engine
CREATE TYPE public.enrollment_status AS ENUM (
  'pending_mentor', 'active', 'completed', 'cancelled', 'disputed'
);
CREATE TYPE public.stage_status AS ENUM (
  'locked', 'in_progress', 'submitted', 'approved', 'changes_requested'
);

-- Commerce / payments
CREATE TYPE public.payment_status AS ENUM (
  'pending', 'held', 'released', 'refunded', 'failed'
);

-- GitHub repo lifecycle
CREATE TYPE public.github_repo_status AS ENUM (
  'not_created',       -- enrollment exists, org repo not yet provisioned
  'active',            -- repo live under skillima-projects org
  'transfer_pending',  -- complete_project() called; API will transfer
  'transferred',       -- repo transferred to student personal account
  'failed'             -- creation or transfer failed — needs admin fix
);

-- Social
CREATE TYPE public.post_type AS ENUM (
  'update', 'milestone', 'showcase', 'question'
);

-- Resale
CREATE TYPE public.resale_status AS ENUM ('listed', 'sold', 'removed');

-- Disputes
CREATE TYPE public.dispute_status AS ENUM (
  'open', 'under_review', 'resolved_refunded', 'resolved_released'
);

-- Notifications (17 typed events)
CREATE TYPE public.notification_type AS ENUM (
  'rank_promotion',
  'stage_approved',
  'stage_changes_requested',
  'stage_submitted',
  'new_message',
  'mentor_accepted',
  'mentor_declined',
  'project_completed',
  'dispute_opened',
  'dispute_resolved',
  'new_follower',
  'post_liked',
  'post_commented',
  'post_reposted',
  'project_enrolled',
  'resale_purchased',
  'streak_achieved'
);

-- Teams (v4.0)
CREATE TYPE public.team_role AS ENUM ('lead', 'member');

-- ================================================================
-- 2. TABLES
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 1: IDENTITY
-- ────────────────────────────────────────────────────────────────

-- 2.1 profiles — Core user record, mirrors auth.users
CREATE TABLE public.profiles (
  id           uuid               NOT NULL PRIMARY KEY
                 REFERENCES auth.users (id) ON DELETE CASCADE,
  email        text               NOT NULL UNIQUE,
  full_name    text               NOT NULL,
  role         public.user_role   NOT NULL DEFAULT 'student',
  status       public.user_status NOT NULL DEFAULT 'active',
  avatar_url   text,
  bio          text,
  fcm_token    text,
  github_url   text,
  linkedin_url text,
  x_url        text,
  created_at   timestamptz        NOT NULL DEFAULT now(),
  updated_at   timestamptz        NOT NULL DEFAULT now()
);

-- 2.2 student_profiles — Student-specific extension (1:1 with profiles)
CREATE TABLE public.student_profiles (
  user_id               uuid                     NOT NULL PRIMARY KEY
                          REFERENCES public.profiles (id) ON DELETE CASCADE,
  rank_points           integer                  NOT NULL DEFAULT 0  CHECK (rank_points >= 0),
  rank_tier             public.rank_tier_student NOT NULL DEFAULT 'novice',
  completed_projects    integer                  NOT NULL DEFAULT 0  CHECK (completed_projects >= 0),
  total_spent_paise     bigint                   NOT NULL DEFAULT 0  CHECK (total_spent_paise >= 0),
  streak_days           integer                  NOT NULL DEFAULT 0  CHECK (streak_days >= 0),
  last_active_date      date,
  learning_goals        text,
  -- GitHub username (no @ prefix, e.g. 'akash-dev').
  -- Populated once by the student in Settings → GitHub.
  -- Used to: (a) add student as org repo collaborator,
  --          (b) transfer completed repo to student's personal account.
  -- No OAuth token stored — GitHub App manages all automation.
  github_username       text,
  -- v4.0: validation state written back by github-username-validate Edge Fn
  github_username_valid boolean,       -- NULL = not checked yet, true = valid, false = invalid
  github_username_error text,          -- non-NULL only when github_username_valid = false
  created_at            timestamptz    NOT NULL DEFAULT now(),
  updated_at            timestamptz    NOT NULL DEFAULT now()
);

-- 2.3 mentor_profiles — Mentor-specific extension (1:1 with profiles)
CREATE TABLE public.mentor_profiles (
  user_id                  uuid                       NOT NULL PRIMARY KEY
                             REFERENCES public.profiles (id) ON DELETE CASCADE,
  verification_status      public.verification_status NOT NULL DEFAULT 'pending',
  verified_by              uuid
                             REFERENCES public.profiles (id) ON DELETE SET NULL,
  years_experience         smallint                   NOT NULL DEFAULT 0
                             CHECK (years_experience >= 0),
  expertise                text[]                     NOT NULL DEFAULT '{}',
  rank_points              integer                    NOT NULL DEFAULT 0
                             CHECK (rank_points >= 0),
  rank_tier                public.rank_tier_mentor    NOT NULL DEFAULT 'guide',
  average_rating           numeric(3,2)               NOT NULL DEFAULT 0.00
                             CHECK (average_rating BETWEEN 0 AND 5),
  total_earnings_paise     bigint                     NOT NULL DEFAULT 0
                             CHECK (total_earnings_paise >= 0),
  available_for_mentorship boolean                    NOT NULL DEFAULT true,
  max_concurrent_students  smallint                   NOT NULL DEFAULT 5
                             CHECK (max_concurrent_students BETWEEN 1 AND 20),
  created_at               timestamptz                NOT NULL DEFAULT now(),
  updated_at               timestamptz                NOT NULL DEFAULT now()
);

-- 2.4 mentor_invitations — Cold-start seeding for new mentors
CREATE TABLE public.mentor_invitations (
  id          uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text        NOT NULL,
  invited_by  uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  token       text        NOT NULL UNIQUE
                DEFAULT encode(gen_random_bytes(32), 'hex'),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '7 days',
  accepted_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 2: SKILL GRAPH
-- ────────────────────────────────────────────────────────────────

-- 2.5 skills — Atomic skill tags (admin-managed lookup)
CREATE TABLE public.skills (
  id         uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text        NOT NULL UNIQUE,
  slug       text        NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 2.6 guilds — Curated skill communities (10 seeded at end of file)
CREATE TABLE public.guilds (
  id            uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        NOT NULL UNIQUE,
  slug          text        NOT NULL UNIQUE,
  description   text,
  icon_url      text,
  banner_url    text,
  member_count  integer     NOT NULL DEFAULT 0 CHECK (member_count >= 0),
  project_count integer     NOT NULL DEFAULT 0 CHECK (project_count >= 0),
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- 2.7 guild_memberships — User ↔ Guild M2M
CREATE TABLE public.guild_memberships (
  user_id   uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  guild_id  uuid        NOT NULL REFERENCES public.guilds   (id) ON DELETE CASCADE,
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, guild_id)
);

-- 2.8 guild_skills — Guild ↔ Skill M2M (guild taxonomy)
CREATE TABLE public.guild_skills (
  guild_id uuid NOT NULL REFERENCES public.guilds  (id) ON DELETE CASCADE,
  skill_id uuid NOT NULL REFERENCES public.skills  (id) ON DELETE CASCADE,
  PRIMARY KEY (guild_id, skill_id)
);

-- 2.9 user_skills — User skill declarations with proficiency level
CREATE TABLE public.user_skills (
  user_id           uuid                    NOT NULL
                      REFERENCES public.profiles (id) ON DELETE CASCADE,
  skill_id          uuid                    NOT NULL
                      REFERENCES public.skills   (id) ON DELETE CASCADE,
  proficiency_level public.proficiency_level NOT NULL DEFAULT 'beginner',
  PRIMARY KEY (user_id, skill_id)
);

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 3: PROJECT MARKETPLACE
-- ────────────────────────────────────────────────────────────────

-- 2.10 projects — Marketplace listings authored by mentors
CREATE TABLE public.projects (
  id                uuid                      NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  mentor_id         uuid                      NOT NULL
                      REFERENCES public.profiles (id) ON DELETE RESTRICT,
  guild_id          uuid                      NOT NULL
                      REFERENCES public.guilds   (id) ON DELETE RESTRICT,
  title             text                      NOT NULL,
  slug              text                      NOT NULL UNIQUE,
  description       text                      NOT NULL,
  difficulty        public.project_difficulty NOT NULL,
  estimated_weeks   smallint                  NOT NULL CHECK (estimated_weeks > 0),
  price_paise       bigint                    NOT NULL DEFAULT 0 CHECK (price_paise >= 0),
  is_app_sponsored  boolean                   NOT NULL DEFAULT false,
  learning_outcomes text[]                    NOT NULL DEFAULT '{}',
  prerequisites     text[]                    NOT NULL DEFAULT '{}',
  tech_stack        text[]                    NOT NULL DEFAULT '{}',
  status            public.project_status     NOT NULL DEFAULT 'draft',
  enrollment_count  integer                   NOT NULL DEFAULT 0 CHECK (enrollment_count >= 0),
  average_rating    numeric(3,2)              NOT NULL DEFAULT 0.00
                      CHECK (average_rating BETWEEN 0 AND 5),
  created_at        timestamptz               NOT NULL DEFAULT now(),
  updated_at        timestamptz               NOT NULL DEFAULT now()
);

-- 2.11 project_skills — Project ↔ Skill M2M tags
CREATE TABLE public.project_skills (
  project_id uuid NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
  skill_id   uuid NOT NULL REFERENCES public.skills   (id) ON DELETE CASCADE,
  PRIMARY KEY (project_id, skill_id)
);

-- 2.12 project_stages — Ordered milestone templates for a project
CREATE TABLE public.project_stages (
  id                 uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id         uuid     NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
  stage_number       smallint NOT NULL,
  title              text     NOT NULL,
  description        text     NOT NULL,
  deliverables       text[]   NOT NULL DEFAULT '{}',
  estimated_hours    smallint NOT NULL CHECK (estimated_hours > 0),
  points_on_complete smallint NOT NULL DEFAULT 10 CHECK (points_on_complete > 0),
  UNIQUE (project_id, stage_number)
);

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 4: TEAMS (v4.0)
-- ────────────────────────────────────────────────────────────────

-- 2.13 teams — A named group of students that enroll together
--   One team enrolls in one project at a time.
--   A student can belong to multiple teams (different projects).
--   The lead (created_by) is responsible for payment.
CREATE TABLE public.teams (
  id          uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL CHECK (char_length(name) BETWEEN 2 AND 80),
  created_by  uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  max_size    smallint    NOT NULL DEFAULT 4 CHECK (max_size BETWEEN 2 AND 8),
  -- Invite code: 8-char uppercase hex; members share this to join before enrollment
  invite_code text        NOT NULL UNIQUE
                DEFAULT upper(substring(encode(gen_random_bytes(4), 'hex'), 1, 8)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.teams IS
  'A named group of students that enroll in a project together. '
  'The lead (created_by) initiates and pays for the enrollment. '
  'Members join via invite_code before the team enrolls.';

-- 2.14 team_members — M2M junction: team ↔ profiles
--   Exactly ONE lead per team enforced by partial unique index below.
CREATE TABLE public.team_members (
  team_id   uuid             NOT NULL REFERENCES public.teams    (id) ON DELETE CASCADE,
  user_id   uuid             NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  role      public.team_role NOT NULL DEFAULT 'member',
  joined_at timestamptz      NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, user_id)
);

COMMENT ON TABLE public.team_members IS
  'M2M junction between teams and profiles. '
  'Exactly one lead per team enforced by partial unique index. '
  'A user can belong to multiple teams for different projects.';

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 5: MENTORSHIP ENGINE
-- ────────────────────────────────────────────────────────────────

-- 2.15 project_enrollments — Live project instance (one per purchase)
--   team_id IS NULL     → solo enrollment (existing behaviour)
--   team_id IS NOT NULL → team enrollment; student_id = lead (payer)
CREATE TABLE public.project_enrollments (
  id                   uuid                      NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid                      NOT NULL
                         REFERENCES public.projects (id) ON DELETE RESTRICT,
  student_id           uuid                      NOT NULL
                         REFERENCES public.profiles (id) ON DELETE RESTRICT,
  mentor_id            uuid
                         REFERENCES public.profiles (id) ON DELETE SET NULL,
  -- v4.0: NULL for solo, set for team enrollments
  team_id              uuid
                         REFERENCES public.teams (id) ON DELETE RESTRICT,
  status               public.enrollment_status  NOT NULL DEFAULT 'pending_mentor',
  -- github_repo_url:
  --   During project : https://github.com/skillima-projects/{github_repo_name}
  --   After transfer : https://github.com/{student_github_username}/{github_repo_name}
  github_repo_url      text,
  -- Immutable once set. Format: '{student-slug}-{project-slug}' (max 100 chars, URL-safe).
  -- Generated server-side at enrollment creation. Never changed after first write.
  github_repo_name     text
                         CHECK (
                           github_repo_name IS NULL
                           OR (char_length(github_repo_name) BETWEEN 1 AND 100
                               AND github_repo_name ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$')
                         ),
  -- Lifecycle: not_created → active → transfer_pending → transferred (or failed)
  -- ONLY writable by service_role or SECURITY DEFINER functions.
  -- prevent_sensitive_enrollment_update trigger enforces this.
  github_status        public.github_repo_status NOT NULL DEFAULT 'not_created',
  current_stage        smallint                  NOT NULL DEFAULT 1,
  purchase_price_paise bigint                    NOT NULL CHECK (purchase_price_paise >= 0),
  -- payment_status set to 'held' by the payment webhook (service_role) at purchase time.
  -- NOT changed by initialize_stage_progress.
  payment_status       public.payment_status     NOT NULL DEFAULT 'pending',
  payment_reference    text,
  mentor_deadline_at   timestamptz,
  started_at           timestamptz,
  completed_at         timestamptz,
  student_rating       smallint CHECK (student_rating BETWEEN 1 AND 5),
  mentor_rating        smallint CHECK (mentor_rating BETWEEN 1 AND 5),
  created_at           timestamptz               NOT NULL DEFAULT now(),
  updated_at           timestamptz               NOT NULL DEFAULT now(),
  -- Prevent a student from purchasing the same project twice (solo)
  UNIQUE (student_id, project_id),
  -- Prevent a team from enrolling in the same project twice
  -- (enforced via partial unique index below — UNIQUE constraint can't filter NULLs)
  -- A mentor cannot enroll in their own project
  CHECK (student_id <> mentor_id)
);

COMMENT ON COLUMN public.project_enrollments.team_id IS
  'NULL for solo enrollments. Set to the team id for team enrollments. '
  'student_id always holds the lead member (payer). All team members '
  'are in team_members and get collaborator access on the GitHub repo.';

-- 2.16 stage_progress — Per-enrollment, per-stage tracking
CREATE TABLE public.stage_progress (
  id                 uuid                NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id      uuid                NOT NULL
                       REFERENCES public.project_enrollments (id) ON DELETE CASCADE,
  stage_id           uuid                NOT NULL
                       REFERENCES public.project_stages      (id) ON DELETE CASCADE,
  status             public.stage_status NOT NULL DEFAULT 'locked',
  mentor_feedback    text,
  points_earned      smallint            NOT NULL DEFAULT 0 CHECK (points_earned >= 0),
  iteration_count    smallint            NOT NULL DEFAULT 0 CHECK (iteration_count >= 0),
  submitted_at       timestamptz,
  reviewed_at        timestamptz,
  -- Set by initialize_stage_progress(); format: 'stage/N'
  github_branch_name text,
  -- Set by the GitHub App API when PR is opened. Retained after merge for audit.
  github_pr_number   integer             CHECK (github_pr_number > 0),
  created_at         timestamptz         NOT NULL DEFAULT now(),
  updated_at         timestamptz         NOT NULL DEFAULT now(),
  UNIQUE (enrollment_id, stage_id)
);

-- 2.17 messages — In-app chat scoped to one enrollment
CREATE TABLE public.messages (
  id            uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id uuid        NOT NULL
                  REFERENCES public.project_enrollments (id) ON DELETE CASCADE,
  sender_id     uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  content       text        NOT NULL CHECK (char_length(content) > 0),
  media_urls    text[]      NOT NULL DEFAULT '{}',
  is_read       boolean     NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- 2.18 disputes — Conflict resolution tickets
CREATE TABLE public.disputes (
  id            uuid                  NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id uuid                  NOT NULL
                  REFERENCES public.project_enrollments (id) ON DELETE RESTRICT,
  raised_by     uuid                  NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  reason        text                  NOT NULL CHECK (char_length(reason) > 0),
  status        public.dispute_status NOT NULL DEFAULT 'open',
  admin_notes   text,
  resolved_by   uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  resolved_at   timestamptz,
  created_at    timestamptz           NOT NULL DEFAULT now(),
  updated_at    timestamptz           NOT NULL DEFAULT now()
);

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 6: SOCIAL LAYER
-- ────────────────────────────────────────────────────────────────

-- 2.19 posts — Feed content
CREATE TABLE public.posts (
  id             uuid             NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id      uuid             NOT NULL REFERENCES public.profiles          (id) ON DELETE CASCADE,
  post_type      public.post_type NOT NULL,
  content        text             NOT NULL CHECK (char_length(content) > 0),
  media_urls     text[]           NOT NULL DEFAULT '{}',
  guild_id       uuid             REFERENCES public.guilds              (id) ON DELETE SET NULL,
  enrollment_id  uuid             REFERENCES public.project_enrollments (id) ON DELETE SET NULL,
  parent_post_id uuid             REFERENCES public.posts               (id) ON DELETE SET NULL,
  likes_count    integer          NOT NULL DEFAULT 0 CHECK (likes_count >= 0),
  comments_count integer          NOT NULL DEFAULT 0 CHECK (comments_count >= 0),
  reposts_count  integer          NOT NULL DEFAULT 0 CHECK (reposts_count >= 0),
  is_repost      boolean          NOT NULL DEFAULT false,
  is_deleted     boolean          NOT NULL DEFAULT false,
  created_at     timestamptz      NOT NULL DEFAULT now(),
  updated_at     timestamptz      NOT NULL DEFAULT now()
);

-- 2.20 post_hashtags — Hashtag M2M on posts
CREATE TABLE public.post_hashtags (
  post_id uuid NOT NULL REFERENCES public.posts (id) ON DELETE CASCADE,
  hashtag text NOT NULL CHECK (char_length(hashtag) > 0),
  PRIMARY KEY (post_id, hashtag)
);

-- 2.21 comments — Threaded replies
CREATE TABLE public.comments (
  id         uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    uuid        NOT NULL REFERENCES public.posts    (id) ON DELETE CASCADE,
  author_id  uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  parent_id  uuid             REFERENCES public.comments (id) ON DELETE CASCADE,
  content    text        NOT NULL CHECK (char_length(content) > 0),
  is_deleted boolean     NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2.22 likes — Post reactions (one per user per post)
CREATE TABLE public.likes (
  id         uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    uuid        NOT NULL REFERENCES public.posts    (id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (post_id, user_id)
);

-- 2.23 bookmarks — Saved posts (private to owner)
CREATE TABLE public.bookmarks (
  user_id    uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  post_id    uuid        NOT NULL REFERENCES public.posts    (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, post_id)
);

-- 2.24 follows — User-to-user follow graph
CREATE TABLE public.follows (
  follower_id  uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  following_id uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, following_id),
  CHECK (follower_id <> following_id)
);

-- 2.25 notifications — In-app inbox (written by SECURITY DEFINER fns only)
CREATE TABLE public.notifications (
  id                uuid                    NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id      uuid                    NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  actor_id          uuid                         REFERENCES public.profiles (id) ON DELETE SET NULL,
  notification_type public.notification_type NOT NULL,
  reference_id      uuid,
  body              text,
  is_read           boolean                 NOT NULL DEFAULT false,
  created_at        timestamptz             NOT NULL DEFAULT now()
);

-- ────────────────────────────────────────────────────────────────
-- DOMAIN 7: COMMERCE
-- ────────────────────────────────────────────────────────────────

-- 2.26 resale_listings — Secondary market listings
CREATE TABLE public.resale_listings (
  id                 uuid                 NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id      uuid                 NOT NULL UNIQUE
                       REFERENCES public.project_enrollments (id) ON DELETE RESTRICT,
  seller_id          uuid                 NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  resale_price_paise bigint               NOT NULL CHECK (resale_price_paise > 0),
  admin_approved     boolean              NOT NULL DEFAULT false,
  status             public.resale_status NOT NULL DEFAULT 'listed',
  created_at         timestamptz          NOT NULL DEFAULT now(),
  updated_at         timestamptz          NOT NULL DEFAULT now()
);

-- 2.27 resale_purchases — Secondary market purchase records
CREATE TABLE public.resale_purchases (
  id                          uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  uuid        NOT NULL REFERENCES public.resale_listings (id) ON DELETE RESTRICT,
  buyer_id                    uuid        NOT NULL REFERENCES public.profiles        (id) ON DELETE RESTRICT,
  purchase_price_paise        bigint      NOT NULL CHECK (purchase_price_paise > 0),
  original_student_commission bigint      NOT NULL CHECK (original_student_commission >= 0),
  platform_commission         bigint      NOT NULL CHECK (platform_commission >= 0),
  payment_reference           text,
  purchased_at                timestamptz NOT NULL DEFAULT now()
);

-- 2.28 rank_history — Immutable append-only points ledger
CREATE TABLE public.rank_history (
  id            uuid        NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  action        text        NOT NULL,
  points_earned integer     NOT NULL,
  balance_after integer     NOT NULL CHECK (balance_after >= 0),
  previous_rank text,
  new_rank      text,
  reference_id  uuid,    -- polymorphic: enrollment / post / etc.
  created_at    timestamptz NOT NULL DEFAULT now()
  -- No updated_at: IMMUTABLE. No UPDATE or DELETE allowed for authenticated users.
);

-- ================================================================
-- 3. REPLICA IDENTITY — Required for Supabase Realtime on DELETE events
-- ================================================================
ALTER TABLE public.messages            REPLICA IDENTITY FULL;
ALTER TABLE public.notifications       REPLICA IDENTITY FULL;
ALTER TABLE public.posts               REPLICA IDENTITY FULL;
ALTER TABLE public.stage_progress      REPLICA IDENTITY FULL;
ALTER TABLE public.project_enrollments REPLICA IDENTITY FULL;

-- ================================================================
-- 4. INDEXES
-- ================================================================

-- ── profiles ──────────────────────────────────────────────────────
CREATE INDEX idx_profiles_role   ON public.profiles (role);
CREATE INDEX idx_profiles_status ON public.profiles (status);
CREATE INDEX idx_profiles_full_name_trgm
  ON public.profiles USING gin (full_name gin_trgm_ops);

-- ── student_profiles ──────────────────────────────────────────────
-- GitHub username lookup (webhook event → student row)
CREATE INDEX idx_student_profiles_github
  ON public.student_profiles (github_username)
  WHERE github_username IS NOT NULL;

-- ── mentor_profiles ───────────────────────────────────────────────
CREATE INDEX idx_mentor_profiles_verification
  ON public.mentor_profiles (verification_status);
CREATE INDEX idx_mentor_profiles_available
  ON public.mentor_profiles (available_for_mentorship)
  WHERE available_for_mentorship = true;
CREATE INDEX idx_mentor_profiles_rating
  ON public.mentor_profiles (average_rating DESC);

-- ── skills ────────────────────────────────────────────────────────
CREATE INDEX idx_skills_slug      ON public.skills (slug);
CREATE INDEX idx_skills_name_trgm ON public.skills USING gin (name gin_trgm_ops);

-- ── guilds ────────────────────────────────────────────────────────
CREATE INDEX idx_guilds_slug   ON public.guilds (slug);
CREATE INDEX idx_guilds_active ON public.guilds (is_active) WHERE is_active = true;

-- ── guild_memberships ─────────────────────────────────────────────
CREATE INDEX idx_guild_memberships_user  ON public.guild_memberships (user_id);
CREATE INDEX idx_guild_memberships_guild ON public.guild_memberships (guild_id);

-- ── projects ──────────────────────────────────────────────────────
CREATE INDEX idx_projects_mentor     ON public.projects (mentor_id);
CREATE INDEX idx_projects_guild      ON public.projects (guild_id);
CREATE INDEX idx_projects_status     ON public.projects (status);
CREATE INDEX idx_projects_difficulty ON public.projects (difficulty);
CREATE INDEX idx_projects_slug       ON public.projects (slug);
CREATE INDEX idx_projects_sponsored  ON public.projects (is_app_sponsored)
  WHERE is_app_sponsored = true;
CREATE INDEX idx_projects_published  ON public.projects (guild_id, difficulty, price_paise)
  WHERE status = 'published';
CREATE INDEX idx_projects_fts        ON public.projects
  USING gin (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, '')));
CREATE INDEX idx_projects_title_trgm ON public.projects USING gin (title gin_trgm_ops);

-- ── project_stages ────────────────────────────────────────────────
CREATE INDEX idx_project_stages_project
  ON public.project_stages (project_id, stage_number);

-- ── teams (v4.0) ──────────────────────────────────────────────────
CREATE INDEX idx_teams_invite_code ON public.teams (invite_code);
CREATE INDEX idx_teams_created_by  ON public.teams (created_by);

-- ── team_members (v4.0) ───────────────────────────────────────────
-- Partial unique: exactly ONE lead per team
CREATE UNIQUE INDEX idx_team_members_one_lead
  ON public.team_members (team_id)
  WHERE role = 'lead';
CREATE INDEX idx_team_members_user ON public.team_members (user_id);
CREATE INDEX idx_team_members_team ON public.team_members (team_id);

-- ── project_enrollments ───────────────────────────────────────────
CREATE INDEX idx_enrollments_student  ON public.project_enrollments (student_id);
CREATE INDEX idx_enrollments_mentor   ON public.project_enrollments (mentor_id);
CREATE INDEX idx_enrollments_project  ON public.project_enrollments (project_id);
CREATE INDEX idx_enrollments_status   ON public.project_enrollments (status);
-- Pending enrollments need deadline monitoring
CREATE INDEX idx_enrollments_deadline ON public.project_enrollments (mentor_deadline_at)
  WHERE status = 'pending_mentor';
-- Enrollments awaiting GitHub transfer or with failed repos (cron retry)
CREATE INDEX idx_enrollments_github_status
  ON public.project_enrollments (github_status, updated_at DESC)
  WHERE github_status IN ('transfer_pending', 'failed');
-- Webhook lookup: GitHub event fires with repo name
CREATE UNIQUE INDEX idx_enrollments_github_repo_name
  ON public.project_enrollments (github_repo_name)
  WHERE github_repo_name IS NOT NULL;
-- v4.0: team enrollment duplicate prevention
CREATE UNIQUE INDEX idx_enrollments_team_project
  ON public.project_enrollments (team_id, project_id)
  WHERE team_id IS NOT NULL;
CREATE INDEX idx_enrollments_team_id
  ON public.project_enrollments (team_id)
  WHERE team_id IS NOT NULL;

-- ── stage_progress ────────────────────────────────────────────────
CREATE INDEX idx_stage_progress_enrollment
  ON public.stage_progress (enrollment_id);
CREATE INDEX idx_stage_progress_status
  ON public.stage_progress (enrollment_id, status);
-- PR number lookup (GitHub webhook → stage row)
CREATE INDEX idx_stage_progress_github_pr
  ON public.stage_progress (github_pr_number)
  WHERE github_pr_number IS NOT NULL;
-- Branch name lookup
CREATE INDEX idx_stage_progress_branch
  ON public.stage_progress (enrollment_id, github_branch_name)
  WHERE github_branch_name IS NOT NULL;

-- ── messages ──────────────────────────────────────────────────────
CREATE INDEX idx_messages_enrollment ON public.messages (enrollment_id, created_at DESC);
CREATE INDEX idx_messages_sender     ON public.messages (sender_id);
CREATE INDEX idx_messages_unread     ON public.messages (enrollment_id)
  WHERE is_read = false;

-- ── disputes ──────────────────────────────────────────────────────
CREATE INDEX idx_disputes_enrollment ON public.disputes (enrollment_id);
CREATE INDEX idx_disputes_status     ON public.disputes (status) WHERE status = 'open';

-- ── posts ─────────────────────────────────────────────────────────
CREATE INDEX idx_posts_author       ON public.posts (author_id);
CREATE INDEX idx_posts_guild        ON public.posts (guild_id, created_at DESC)
  WHERE guild_id IS NOT NULL;
CREATE INDEX idx_posts_type         ON public.posts (post_type);
CREATE INDEX idx_posts_created      ON public.posts (created_at DESC);
CREATE INDEX idx_posts_visible      ON public.posts (author_id, created_at DESC)
  WHERE is_deleted = false;
CREATE INDEX idx_posts_fts          ON public.posts
  USING gin (to_tsvector('english', coalesce(content, '')));
CREATE INDEX idx_posts_content_trgm ON public.posts USING gin (content gin_trgm_ops);

-- ── comments ──────────────────────────────────────────────────────
CREATE INDEX idx_comments_post   ON public.comments (post_id);
CREATE INDEX idx_comments_parent ON public.comments (parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX idx_comments_author ON public.comments (author_id);

-- ── likes ─────────────────────────────────────────────────────────
CREATE INDEX idx_likes_post ON public.likes (post_id);
CREATE INDEX idx_likes_user ON public.likes (user_id);

-- ── bookmarks ─────────────────────────────────────────────────────
CREATE INDEX idx_bookmarks_user ON public.bookmarks (user_id, created_at DESC);

-- ── notifications ─────────────────────────────────────────────────
CREATE INDEX idx_notifications_recipient
  ON public.notifications (recipient_id, created_at DESC);
CREATE INDEX idx_notifications_unread
  ON public.notifications (recipient_id)
  WHERE is_read = false;
CREATE INDEX idx_notifications_type ON public.notifications (notification_type);

-- ── rank_history ──────────────────────────────────────────────────
CREATE INDEX idx_rank_history_user   ON public.rank_history (user_id, created_at DESC);
CREATE INDEX idx_rank_history_action ON public.rank_history (action);

-- ── resale_listings ───────────────────────────────────────────────
CREATE INDEX idx_resale_listings_seller ON public.resale_listings (seller_id);
CREATE INDEX idx_resale_listings_status ON public.resale_listings (status);
CREATE INDEX idx_resale_listings_live   ON public.resale_listings (created_at DESC)
  WHERE status = 'listed' AND admin_approved = true;

-- ── resale_purchases ──────────────────────────────────────────────
CREATE INDEX idx_resale_purchases_buyer   ON public.resale_purchases (buyer_id);
CREATE INDEX idx_resale_purchases_listing ON public.resale_purchases (listing_id);

-- ================================================================
-- 5. FUNCTIONS
--
-- ALL functions use SET search_path = '' to prevent schema injection.
-- Fully-qualified names used throughout (public.table, auth.uid()).
-- SECURITY DEFINER: functions that need elevated privileges.
-- SECURITY INVOKER: update_updated_at() only (touches caller-owned row).
-- STABLE: read-only helper functions cached per query (not per row).
-- VOLATILE: explicitly declared on all mutation functions.
-- ================================================================

-- ─────────────────────────────────────────────────────────────────
-- 5.1  update_updated_at
--      Generic BEFORE UPDATE trigger to stamp updated_at = now().
--      SECURITY INVOKER: the calling user already owns the row.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY INVOKER
  SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.2  get_current_user_role
--      Returns the calling user's role enum.
--      STABLE: result cached once per query (init-plan), not per row.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_current_user_role()
  RETURNS public.user_role
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
DECLARE
  _role public.user_role;
BEGIN
  SELECT role
    INTO _role
    FROM public.profiles
   WHERE id = (SELECT auth.uid());
  RETURN _role;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.3  is_admin
--      Boolean admin check used in every admin-gated RLS policy.
--      STABLE: cached once per query.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_admin()
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
      FROM public.profiles
     WHERE id   = (SELECT auth.uid())
       AND role = 'admin'
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.4  is_team_member (v4.0)
--      Returns true if the calling user belongs to the team
--      associated with the given enrollment.
--      Used by is_enrollment_participant() below.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_team_member(_enrollment_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
      FROM public.project_enrollments pe
      JOIN public.team_members        tm ON tm.team_id = pe.team_id
     WHERE pe.id      = _enrollment_id
       AND tm.user_id = (SELECT auth.uid())
       AND pe.team_id IS NOT NULL
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.5  is_enrollment_participant (v4.0 — team-aware)
--      Returns true if caller is the student, mentor, OR any team
--      member on the given enrollment.
--      STABLE: cached once per query.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_enrollment_participant(_enrollment_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
      FROM public.project_enrollments
     WHERE id = _enrollment_id
       AND (student_id = (SELECT auth.uid())
            OR  mentor_id = (SELECT auth.uid()))
  )
  OR public.is_team_member(_enrollment_id);
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.6  handle_new_user
--      Fires on auth.users INSERT.
--      Creates profiles row + student_profiles or mentor_profiles
--      based on role in Supabase Auth user metadata.
--      Safe enum cast: invalid role values default to 'student'.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _role        public.user_role   := 'student';
  _raw_role    text;
  _user_status public.user_status;
BEGIN
  _raw_role := NEW.raw_user_meta_data ->> 'role';

  IF _raw_role IN ('student', 'mentor', 'admin') THEN
    _role := _raw_role::public.user_role;
  END IF;

  -- Mentors start as 'pending' until admin approves verification
  _user_status := CASE
    WHEN _role = 'mentor' THEN 'pending'::public.user_status
    ELSE                       'active'::public.user_status
  END;

  INSERT INTO public.profiles (id, email, full_name, role, status)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data ->> 'name'), ''), 'Unknown'),
    _role,
    _user_status
  );

  IF _role = 'student' THEN
    INSERT INTO public.student_profiles (user_id) VALUES (NEW.id);
  ELSIF _role = 'mentor' THEN
    INSERT INTO public.mentor_profiles (user_id) VALUES (NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.7  award_rank_points
--      Atomically:
--        • Updates rank_points + recalculates tier
--        • Inserts immutable rank_history ledger row
--        • Fires rank_promotion notification if tier changed
--
--      SECURITY DEFINER: runs as postgres.
--      REVOKE from authenticated after grants (Section 8).
--      Only callable by service_role or other SECURITY DEFINER functions.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.award_rank_points(
  _user_id      uuid,
  _points       integer,
  _action       text,
  _reference_id uuid DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _role           public.user_role;
  _current_pts    integer;
  _new_pts        integer;
  _prev_rank_text text;
  _new_rank_text  text;
BEGIN
  SELECT role INTO _role FROM public.profiles WHERE id = _user_id;

  IF _role = 'student' THEN
    SELECT rank_points, rank_tier::text
      INTO _current_pts, _prev_rank_text
      FROM public.student_profiles
     WHERE user_id = _user_id;

    _new_pts := GREATEST(0, _current_pts + _points);

    _new_rank_text := CASE
      WHEN _new_pts <=   100 THEN 'novice'
      WHEN _new_pts <=   300 THEN 'apprentice'
      WHEN _new_pts <=   600 THEN 'journeyman'
      WHEN _new_pts <=  1000 THEN 'craftsman'
      WHEN _new_pts <=  1500 THEN 'expert'
      WHEN _new_pts <=  2500 THEN 'master'
      ELSE                        'grandmaster'
    END;

    UPDATE public.student_profiles
       SET rank_points = _new_pts,
           rank_tier   = _new_rank_text::public.rank_tier_student,
           updated_at  = now()
     WHERE user_id = _user_id;

  ELSIF _role = 'mentor' THEN
    SELECT rank_points, rank_tier::text
      INTO _current_pts, _prev_rank_text
      FROM public.mentor_profiles
     WHERE user_id = _user_id;

    _new_pts := GREATEST(0, _current_pts + _points);

    _new_rank_text := CASE
      WHEN _new_pts <=   150 THEN 'guide'
      WHEN _new_pts <=   400 THEN 'instructor'
      WHEN _new_pts <=   800 THEN 'sage'
      WHEN _new_pts <=  1500 THEN 'virtuoso'
      WHEN _new_pts <=  2500 THEN 'luminary'
      ELSE                        'legend'
    END;

    UPDATE public.mentor_profiles
       SET rank_points = _new_pts,
           rank_tier   = _new_rank_text::public.rank_tier_mentor,
           updated_at  = now()
     WHERE user_id = _user_id;

  ELSE
    -- admins do not accumulate rank points
    RETURN;
  END IF;

  -- Append immutable ledger row
  INSERT INTO public.rank_history
    (user_id, action, points_earned, balance_after, previous_rank, new_rank, reference_id)
  VALUES
    (_user_id, _action, _points, _new_pts, _prev_rank_text, _new_rank_text, _reference_id);

  -- Fire rank_promotion notification if tier changed
  IF _prev_rank_text IS DISTINCT FROM _new_rank_text THEN
    INSERT INTO public.notifications
      (recipient_id, notification_type, reference_id, body)
    VALUES
      (_user_id, 'rank_promotion', _reference_id,
       'Congratulations! You have been promoted to ' || _new_rank_text || '.');
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.8  award_team_stage_points (v4.0)
--      Loops all team_members and calls award_rank_points() for each.
--      Called by approve_stage() and complete_project() when team_id IS NOT NULL.
--      REVOKE from authenticated after grants.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.award_team_stage_points(
  _team_id      uuid,
  _points       integer,
  _action       text,
  _reference_id uuid DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _member_id uuid;
BEGIN
  FOR _member_id IN
    SELECT user_id FROM public.team_members WHERE team_id = _team_id
  LOOP
    PERFORM public.award_rank_points(_member_id, _points, _action, _reference_id);
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.9  initialize_stage_progress
--      Called (via RPC) when a mentor accepts an enrollment.
--      Creates stage_progress rows for every project stage.
--      Sets Stage 1 to in_progress, all others to locked.
--      Sets enrollment.status = 'active', records started_at.
--      Does NOT touch payment_status (set by payment webhook at purchase).
--      Sets github_branch_name = 'stage/N' for each row.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.initialize_stage_progress(_enrollment_id uuid)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _project_id uuid;
  _stage      record;
  _is_first   boolean := true;
BEGIN
  SELECT project_id INTO _project_id
    FROM public.project_enrollments
   WHERE id = _enrollment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Enrollment % not found', _enrollment_id;
  END IF;

  FOR _stage IN
    SELECT id, stage_number
      FROM public.project_stages
     WHERE project_id = _project_id
     ORDER BY stage_number ASC
  LOOP
    INSERT INTO public.stage_progress (
      enrollment_id,
      stage_id,
      status,
      github_branch_name   -- 'stage/N' consumed by GitHub App to create branch + PR
    )
    VALUES (
      _enrollment_id,
      _stage.id,
      CASE WHEN _is_first THEN 'in_progress'::public.stage_status
           ELSE                'locked'::public.stage_status END,
      'stage/' || _stage.stage_number
    );
    _is_first := false;
  END LOOP;

  -- Allow the column guard trigger to pass for this internal UPDATE
  SET LOCAL skillima.internal_context = 'system';

  -- Mark enrollment active. payment_status is untouched — was set at purchase time.
  UPDATE public.project_enrollments
     SET status             = 'active',
         started_at         = now(),
         mentor_deadline_at = NULL,
         updated_at         = now()
   WHERE id = _enrollment_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.10 approve_stage (v4.0 — team-aware)
--      Mentor approves a submitted stage.
--      Guards: caller must be assigned mentor; stage must be 'submitted'.
--      Awards points to student/all team members + mentor.
--      Unlocks next stage. Notifies student + all team members.
--      DB trigger fires github-stage-approve Edge Fn after this UPDATE.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.approve_stage(
  _stage_progress_id uuid,
  _feedback          text DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _sp         record;
  _enrollment record;
  _next_stage record;
  _pts        integer;
BEGIN
  -- Load stage_progress joined with its project_stages template
  SELECT sp.*,
         ps.stage_number,
         ps.points_on_complete,
         ps.project_id
    INTO _sp
    FROM public.stage_progress sp
    JOIN public.project_stages ps ON ps.id = sp.stage_id
   WHERE sp.id = _stage_progress_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'stage_progress row % not found', _stage_progress_id;
  END IF;

  SELECT * INTO _enrollment
    FROM public.project_enrollments
   WHERE id = _sp.enrollment_id;

  IF _enrollment.mentor_id IS DISTINCT FROM (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'Only the assigned mentor can approve stages';
  END IF;

  IF _sp.status <> 'submitted' THEN
    RAISE EXCEPTION 'Stage must be in submitted status to approve (current: %)', _sp.status;
  END IF;

  _pts := _sp.points_on_complete;

  -- Allow column guard trigger on the enrollment UPDATE below
  SET LOCAL skillima.internal_context = 'system';

  -- Mark this stage approved
  UPDATE public.stage_progress
     SET status          = 'approved',
         mentor_feedback = _feedback,
         points_earned   = _pts,
         reviewed_at     = now(),
         updated_at      = now()
   WHERE id = _stage_progress_id;

  -- Unlock next stage if one exists
  SELECT ps.id, ps.stage_number INTO _next_stage
    FROM public.project_stages ps
   WHERE ps.project_id  = _sp.project_id
     AND ps.stage_number = _sp.stage_number + 1;

  IF FOUND THEN
    UPDATE public.stage_progress
       SET status     = 'in_progress',
           updated_at = now()
     WHERE enrollment_id = _sp.enrollment_id
       AND stage_id      = _next_stage.id;

    UPDATE public.project_enrollments
       SET current_stage = _sp.stage_number + 1,
           updated_at    = now()
     WHERE id = _sp.enrollment_id;
  END IF;

  -- ── Point distribution: team vs solo ───────────────────────────
  IF _enrollment.team_id IS NOT NULL THEN
    -- All team members earn the stage points
    PERFORM public.award_team_stage_points(
      _enrollment.team_id, _pts, 'stage_approved', _sp.enrollment_id
    );
  ELSE
    -- Solo: only the student earns points
    PERFORM public.award_rank_points(
      _enrollment.student_id, _pts, 'stage_approved', _sp.enrollment_id
    );
  END IF;

  -- Mentor always earns half points (min 1) regardless of team/solo
  PERFORM public.award_rank_points(
    _enrollment.mentor_id, GREATEST(1, _pts / 2), 'stage_reviewed', _sp.enrollment_id
  );

  -- Notify lead student (or solo student)
  INSERT INTO public.notifications
    (recipient_id, actor_id, notification_type, reference_id, body)
  VALUES
    (_enrollment.student_id, (SELECT auth.uid()),
     'stage_approved', _stage_progress_id, 'Your stage has been approved!');

  -- Notify remaining team members (v4.0)
  IF _enrollment.team_id IS NOT NULL THEN
    INSERT INTO public.notifications
      (recipient_id, actor_id, notification_type, reference_id, body)
    SELECT
      tm.user_id,
      (SELECT auth.uid()),
      'stage_approved',
      _stage_progress_id,
      'Your team stage has been approved!'
    FROM public.team_members tm
    WHERE tm.team_id = _enrollment.team_id
      AND tm.user_id <> _enrollment.student_id;
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.11 complete_project (v4.0 — team-aware)
--      Finalises an enrollment when ALL stages are approved.
--      Guards: caller must be assigned mentor; all stages must be approved.
--      Releases escrow, awards difficulty-scaled bonus to all members,
--      sets github_status = 'transfer_pending' (triggers Edge Fn),
--      increments completed_projects for all members, notifies all.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.complete_project(_enrollment_id uuid)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _enrollment  record;
  _any_pending boolean;
  _difficulty  public.project_difficulty;
  _bonus_pts   integer;
BEGIN
  SELECT * INTO _enrollment
    FROM public.project_enrollments
   WHERE id = _enrollment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Enrollment % not found', _enrollment_id;
  END IF;

  IF _enrollment.mentor_id IS DISTINCT FROM (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'Only the assigned mentor can complete the project';
  END IF;

  -- Verify all stages approved
  SELECT EXISTS (
    SELECT 1
      FROM public.stage_progress sp
      JOIN public.project_stages ps ON ps.id = sp.stage_id
     WHERE sp.enrollment_id = _enrollment_id
       AND sp.status <> 'approved'
  ) INTO _any_pending;

  IF _any_pending THEN
    RAISE EXCEPTION 'All stages must be approved before completing the project';
  END IF;

  SELECT difficulty INTO _difficulty
    FROM public.projects
   WHERE id = _enrollment.project_id;

  -- Difficulty-scaled completion bonus
  _bonus_pts := CASE _difficulty
    WHEN 'beginner'     THEN  50
    WHEN 'intermediate' THEN 100
    WHEN 'advanced'     THEN 125
    WHEN 'expert'       THEN 150
    ELSE                      50
  END;

  -- Allow column guard trigger
  SET LOCAL skillima.internal_context = 'system';

  -- Mark complete, release escrow, signal GitHub transfer
  UPDATE public.project_enrollments
     SET status         = 'completed',
         completed_at   = now(),
         payment_status = 'released',
         github_status  = 'transfer_pending',
         updated_at     = now()
   WHERE id = _enrollment_id;

  -- ── Increment completed_projects counter ───────────────────────
  IF _enrollment.team_id IS NOT NULL THEN
    UPDATE public.student_profiles
       SET completed_projects = completed_projects + 1,
           updated_at         = now()
     WHERE user_id IN (
       SELECT user_id FROM public.team_members WHERE team_id = _enrollment.team_id
     );
  ELSE
    UPDATE public.student_profiles
       SET completed_projects = completed_projects + 1,
           updated_at         = now()
     WHERE user_id = _enrollment.student_id;
  END IF;

  -- ── Award completion bonus ─────────────────────────────────────
  IF _enrollment.team_id IS NOT NULL THEN
    PERFORM public.award_team_stage_points(
      _enrollment.team_id, _bonus_pts, 'project_completed', _enrollment_id
    );
  ELSE
    PERFORM public.award_rank_points(
      _enrollment.student_id, _bonus_pts, 'project_completed', _enrollment_id
    );
  END IF;

  -- Mentor earns 2x completion bonus
  PERFORM public.award_rank_points(
    _enrollment.mentor_id, _bonus_pts * 2, 'project_completed_mentor', _enrollment_id
  );

  -- Notify lead student (or solo student)
  INSERT INTO public.notifications
    (recipient_id, actor_id, notification_type, reference_id, body)
  VALUES
    (_enrollment.student_id, (SELECT auth.uid()),
     'project_completed', _enrollment_id,
     'Congratulations! Your project is complete and your certificate is ready.');

  -- Notify remaining team members (v4.0)
  IF _enrollment.team_id IS NOT NULL THEN
    INSERT INTO public.notifications
      (recipient_id, actor_id, notification_type, reference_id, body)
    SELECT
      tm.user_id,
      (SELECT auth.uid()),
      'project_completed',
      _enrollment_id,
      'Your team project is complete! Your certificate is ready.'
    FROM public.team_members tm
    WHERE tm.team_id = _enrollment.team_id
      AND tm.user_id <> _enrollment.student_id;
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.12 increment_post_counters
--      AFTER trigger: maintains denormalised likes_count and
--      comments_count on posts. Never run COUNT(*) for display.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_post_counters()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
BEGIN
  IF TG_TABLE_NAME = 'likes' THEN
    IF TG_OP = 'INSERT' THEN
      UPDATE public.posts SET likes_count = likes_count + 1 WHERE id = NEW.post_id;
    ELSIF TG_OP = 'DELETE' THEN
      UPDATE public.posts SET likes_count = GREATEST(0, likes_count - 1) WHERE id = OLD.post_id;
    END IF;
  ELSIF TG_TABLE_NAME = 'comments' THEN
    IF TG_OP = 'INSERT' THEN
      UPDATE public.posts SET comments_count = comments_count + 1 WHERE id = NEW.post_id;
    ELSIF TG_OP = 'DELETE' THEN
      UPDATE public.posts SET comments_count = GREATEST(0, comments_count - 1) WHERE id = OLD.post_id;
    END IF;
  END IF;
  RETURN NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.13 update_guild_member_count
--      AFTER trigger: keeps guilds.member_count accurate.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_guild_member_count()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.guilds SET member_count = member_count + 1 WHERE id = NEW.guild_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.guilds SET member_count = GREATEST(0, member_count - 1) WHERE id = OLD.guild_id;
  END IF;
  RETURN NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.14 update_enrollment_count
--      AFTER INSERT trigger: increments projects.enrollment_count
--      for marketplace social proof display.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_enrollment_count()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
BEGIN
  UPDATE public.projects
     SET enrollment_count = enrollment_count + 1
   WHERE id = NEW.project_id;
  RETURN NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.15 update_repost_counter
--      AFTER trigger: keeps posts.reposts_count accurate.
--      WHEN condition on trigger (Section 6) ensures this only fires
--      for actual reposts (parent_post_id IS NOT NULL).
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_repost_counter()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.posts SET reposts_count = reposts_count + 1
     WHERE id = NEW.parent_post_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.posts SET reposts_count = GREATEST(0, reposts_count - 1)
     WHERE id = OLD.parent_post_id;
  END IF;
  RETURN NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.16 prevent_sensitive_enrollment_update
--      BEFORE UPDATE trigger on project_enrollments.
--      Blocks the authenticated role from directly writing system-owned
--      columns. Only service_role (adminSupabase / Edge Functions) and
--      SECURITY DEFINER functions (which SET LOCAL skillima.internal_context)
--      are permitted to change these columns.
--
--      PROTECTED COLUMNS:
--        payment_status   — set by payment webhook (service_role)
--        github_status    — set by GitHub API layer (service_role)
--        github_repo_url  — set by GitHub API layer (service_role)
--        github_repo_name — immutable after first INSERT (service_role)
--        status           — set only by initialize_stage_progress(),
--                           approve_stage(), complete_project()
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.prevent_sensitive_enrollment_update()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
BEGIN
  -- service_role (adminSupabase / Edge Functions) — always allowed
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Internal SECURITY DEFINER functions set this flag before their UPDATE
  IF current_setting('skillima.internal_context', true) = 'system' THEN
    RETURN NEW;
  END IF;

  -- Block authenticated client from changing system-owned columns
  IF auth.role() = 'authenticated' THEN

    IF NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
      RAISE EXCEPTION
        'payment_status is system-managed. Use the payment webhook (service_role) only.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.github_status IS DISTINCT FROM OLD.github_status THEN
      RAISE EXCEPTION
        'github_status is system-managed. Use GitHub server actions (service_role) only.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.github_repo_url IS DISTINCT FROM OLD.github_repo_url THEN
      RAISE EXCEPTION
        'github_repo_url is system-managed. Set automatically by the GitHub integration.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.github_repo_name IS DISTINCT FROM OLD.github_repo_name THEN
      RAISE EXCEPTION
        'github_repo_name is immutable after first write.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION
        'enrollment status is system-managed. Use initialize_stage_progress(), '
        'approve_stage(), or complete_project() RPC calls.'
        USING ERRCODE = '42501';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- v4.0 GITHUB TRIGGER FUNCTIONS (Part A)
--
-- All five functions call pg_net (extensions.net.http_post) to invoke
-- Supabase Edge Functions asynchronously. The Edge Functions hold the
-- GitHub App private key and execute the actual GitHub API calls.
--
-- app.supabase_url and app.service_role_key must be set in
-- Supabase Dashboard → Settings → Database → Custom Config, or via:
--   ALTER DATABASE postgres SET app.supabase_url = 'https://xxxx.supabase.co';
--   ALTER DATABASE postgres SET app.service_role_key = 'eyJ...';
-- ─────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────
-- 5.17 notify_github_stage_submit (v4.0)
--      Fires AFTER UPDATE on stage_progress when status → 'submitted'.
--      Calls github-stage-submit Edge Fn → opens PR stage/N → main.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_github_stage_submit()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url text;
  _key text;
BEGIN
  IF NEW.status <> 'submitted'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'submitted'::public.stage_status THEN RETURN NEW; END IF;
  -- Don't open a second PR if one already exists
  IF NEW.github_pr_number IS NOT NULL               THEN RETURN NEW; END IF;

  _url := current_setting('app.supabase_url', true) || '/functions/v1/github-stage-submit';
  _key := current_setting('app.service_role_key', true);

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('stageProgressId', NEW.id)
  );

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.18 notify_github_stage_approve (v4.0)
--      Fires AFTER UPDATE on stage_progress when status → 'approved'.
--      Calls github-stage-approve Edge Fn → posts APPROVE review,
--      squash-merges PR, creates next stage branch.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_github_stage_approve()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url text;
  _key text;
BEGIN
  IF NEW.status <> 'approved'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'approved'::public.stage_status THEN RETURN NEW; END IF;
  IF NEW.github_pr_number IS NULL                  THEN RETURN NEW; END IF;

  _url := current_setting('app.supabase_url', true) || '/functions/v1/github-stage-approve';
  _key := current_setting('app.service_role_key', true);

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object(
      'stageProgressId', NEW.id,
      'feedback',        NEW.mentor_feedback
    )
  );

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.19 notify_github_stage_changes (v4.0)
--      Fires AFTER UPDATE on stage_progress when status → 'changes_requested'.
--      Calls github-stage-changes Edge Fn → posts REQUEST_CHANGES review.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_github_stage_changes()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url text;
  _key text;
BEGIN
  IF NEW.status <> 'changes_requested'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'changes_requested'::public.stage_status THEN RETURN NEW; END IF;
  IF NEW.github_pr_number IS NULL                           THEN RETURN NEW; END IF;

  _url := current_setting('app.supabase_url', true) || '/functions/v1/github-stage-changes';
  _key := current_setting('app.service_role_key', true);

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object(
      'stageProgressId', NEW.id,
      'feedback',        NEW.mentor_feedback
    )
  );

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.20 notify_github_mentor_added (v4.0)
--      Fires AFTER UPDATE on project_enrollments when status → 'active'.
--      Calls github-mentor-added Edge Fn → adds mentor as Read collaborator
--      and adds ALL team members as Write collaborators on the org repo.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_github_mentor_added()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url text;
  _key text;
BEGIN
  IF NEW.status    <> 'active'::public.enrollment_status THEN RETURN NEW; END IF;
  IF OLD.status     = 'active'::public.enrollment_status THEN RETURN NEW; END IF;
  IF NEW.mentor_id IS NULL                               THEN RETURN NEW; END IF;
  IF NEW.github_repo_name IS NULL                        THEN RETURN NEW; END IF;

  _url := current_setting('app.supabase_url', true) || '/functions/v1/github-mentor-added';
  _key := current_setting('app.service_role_key', true);

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', NEW.id)
  );

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5.21 notify_github_username_set (v4.0)
--      Fires BEFORE UPDATE on student_profiles when github_username changes.
--      Resets github_username_valid + github_username_error immediately.
--      Calls github-username-validate Edge Fn → checks GitHub API,
--      writes back github_username_valid (true/false) and error message.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_github_username_set()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url text;
  _key text;
BEGIN
  -- Only fire when github_username actually changes
  IF NEW.github_username IS NOT DISTINCT FROM OLD.github_username THEN
    RETURN NEW;
  END IF;

  -- Reset validation state immediately on any change
  NEW.github_username_valid := NULL;
  NEW.github_username_error := NULL;

  IF NEW.github_username IS NOT NULL THEN
    _url := current_setting('app.supabase_url', true) || '/functions/v1/github-username-validate';
    _key := current_setting('app.service_role_key', true);

    PERFORM extensions.net.http_post(
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

-- ================================================================
-- 6. TRIGGERS
-- ================================================================

-- ── updated_at triggers (applied to all mutable tables) ───────────

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_student_profiles_updated_at
  BEFORE UPDATE ON public.student_profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_mentor_profiles_updated_at
  BEFORE UPDATE ON public.mentor_profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_guilds_updated_at
  BEFORE UPDATE ON public.guilds
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_projects_updated_at
  BEFORE UPDATE ON public.projects
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- trg_enrollments_column_guard must be named alphabetically BEFORE
-- trg_enrollments_updated_at so the guard fires first within BEFORE UPDATE.
CREATE TRIGGER trg_enrollments_column_guard
  BEFORE UPDATE ON public.project_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sensitive_enrollment_update();

CREATE TRIGGER trg_enrollments_updated_at
  BEFORE UPDATE ON public.project_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_stage_progress_updated_at
  BEFORE UPDATE ON public.stage_progress
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_disputes_updated_at
  BEFORE UPDATE ON public.disputes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_posts_updated_at
  BEFORE UPDATE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_comments_updated_at
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_resale_listings_updated_at
  BEFORE UPDATE ON public.resale_listings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_teams_updated_at
  BEFORE UPDATE ON public.teams
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ── Auth trigger: fires on every new Supabase Auth registration ───

CREATE TRIGGER trg_auth_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── Denormalised counter triggers ─────────────────────────────────

CREATE TRIGGER trg_likes_counter
  AFTER INSERT OR DELETE ON public.likes
  FOR EACH ROW EXECUTE FUNCTION public.increment_post_counters();

CREATE TRIGGER trg_comments_counter
  AFTER INSERT OR DELETE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.increment_post_counters();

CREATE TRIGGER trg_guild_member_count
  AFTER INSERT OR DELETE ON public.guild_memberships
  FOR EACH ROW EXECUTE FUNCTION public.update_guild_member_count();

CREATE TRIGGER trg_enrollment_count
  AFTER INSERT ON public.project_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.update_enrollment_count();

-- WHEN condition: only fires for actual reposts (saves function overhead)
CREATE TRIGGER trg_repost_counter_insert
  AFTER INSERT ON public.posts
  FOR EACH ROW
  WHEN (NEW.parent_post_id IS NOT NULL)
  EXECUTE FUNCTION public.update_repost_counter();

CREATE TRIGGER trg_repost_counter_delete
  AFTER DELETE ON public.posts
  FOR EACH ROW
  WHEN (OLD.parent_post_id IS NOT NULL)
  EXECUTE FUNCTION public.update_repost_counter();

-- ── v4.0 GitHub automation triggers ───────────────────────────────

-- stage_progress status → 'submitted'  : opens GitHub PR
CREATE TRIGGER trg_github_stage_submit
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW EXECUTE FUNCTION public.notify_github_stage_submit();

-- stage_progress status → 'approved'   : approves + merges PR, creates next branch
CREATE TRIGGER trg_github_stage_approve
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW EXECUTE FUNCTION public.notify_github_stage_approve();

-- stage_progress status → 'changes_requested' : posts REQUEST_CHANGES review
CREATE TRIGGER trg_github_stage_changes
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW EXECUTE FUNCTION public.notify_github_stage_changes();

-- enrollment status → 'active' : adds mentor + all team members as collaborators
CREATE TRIGGER trg_github_mentor_added
  AFTER UPDATE ON public.project_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.notify_github_mentor_added();

-- student_profiles github_username changes : validates username + resets flags
CREATE TRIGGER trg_github_username_set
  BEFORE UPDATE ON public.student_profiles
  FOR EACH ROW EXECUTE FUNCTION public.notify_github_username_set();

-- ================================================================
-- 7. ROW LEVEL SECURITY
--
-- RLS enabled on ALL 28 tables.
-- anon role       → zero access to every table.
-- authenticated   → per-policy access controlled below.
-- service_role    → bypasses RLS (used by Edge Functions + adminSupabase).
--
-- RULES applied throughout:
--   (SELECT auth.uid()) in every policy — init-plan caching (not per-row).
--   Every UPDATE policy has an explicit WITH CHECK clause.
--   Per-operation policies (no FOR ALL) for clarity + predictability.
-- ================================================================

ALTER TABLE public.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.student_profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mentor_profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mentor_invitations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.skills              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guilds              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guild_memberships   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guild_skills        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_skills         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_skills      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_stages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.teams               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_members        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stage_progress      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disputes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_hashtags       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookmarks           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.follows             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resale_listings     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resale_purchases    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rank_history        ENABLE ROW LEVEL SECURITY;

-- ────────────────────────────────────────────────────────────────
-- profiles
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "profiles_select_authenticated"
  ON public.profiles FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "profiles_insert_own"
  ON public.profiles FOR INSERT TO authenticated
  WITH CHECK (id = (SELECT auth.uid()));

CREATE POLICY "profiles_update_own_or_admin"
  ON public.profiles FOR UPDATE TO authenticated
  USING      (id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "profiles_delete_admin"
  ON public.profiles FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- student_profiles
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "student_profiles_select_authenticated"
  ON public.student_profiles FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "student_profiles_insert_own"
  ON public.student_profiles FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "student_profiles_update_own_or_admin"
  ON public.student_profiles FOR UPDATE TO authenticated
  USING      (user_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (user_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- mentor_profiles
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "mentor_profiles_select_authenticated"
  ON public.mentor_profiles FOR SELECT TO authenticated
  USING (true);

-- Drop old policies
DROP POLICY "mentor_profiles_insert_own" ON public.mentor_profiles;
DROP POLICY "student_profiles_insert_own" ON public.student_profiles;

-- Only handle_new_user() (SECURITY DEFINER) should insert these.
-- Authenticated users should never insert directly.
-- service_role bypasses RLS so Edge Functions still work.
CREATE POLICY "mentor_profiles_insert_own"
  ON public.mentor_profiles FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.profiles
       WHERE id   = (SELECT auth.uid())
         AND role = 'mentor'
    )
  );

CREATE POLICY "student_profiles_insert_own"
  ON public.student_profiles FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.profiles
       WHERE id   = (SELECT auth.uid())
         AND role = 'student'
    )
  );
CREATE POLICY "mentor_profiles_update_own_or_admin"
  ON public.mentor_profiles FOR UPDATE TO authenticated
  USING      (user_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (user_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- mentor_invitations (fully admin-gated)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "mentor_invitations_admin_select"
  ON public.mentor_invitations FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY "mentor_invitations_admin_insert"
  ON public.mentor_invitations FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "mentor_invitations_admin_update"
  ON public.mentor_invitations FOR UPDATE TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "mentor_invitations_admin_delete"
  ON public.mentor_invitations FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- skills (lookup — read by all, write by admin only)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "skills_select_authenticated"
  ON public.skills FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "skills_insert_admin"
  ON public.skills FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "skills_update_admin"
  ON public.skills FOR UPDATE TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "skills_delete_admin"
  ON public.skills FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- guilds (active ones visible to all; write is admin-only)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "guilds_select_active_or_admin"
  ON public.guilds FOR SELECT TO authenticated
  USING (is_active = true OR public.is_admin());

CREATE POLICY "guilds_insert_admin"
  ON public.guilds FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "guilds_update_admin"
  ON public.guilds FOR UPDATE TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "guilds_delete_admin"
  ON public.guilds FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- guild_memberships
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "guild_memberships_select_authenticated"
  ON public.guild_memberships FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "guild_memberships_insert_own"
  ON public.guild_memberships FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "guild_memberships_delete_own_or_admin"
  ON public.guild_memberships FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- guild_skills (admin manages the taxonomy)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "guild_skills_select_authenticated"
  ON public.guild_skills FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "guild_skills_insert_admin"
  ON public.guild_skills FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "guild_skills_delete_admin"
  ON public.guild_skills FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- user_skills
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "user_skills_select_authenticated"
  ON public.user_skills FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "user_skills_insert_own"
  ON public.user_skills FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "user_skills_update_own"
  ON public.user_skills FOR UPDATE TO authenticated
  USING      (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "user_skills_delete_own"
  ON public.user_skills FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ────────────────────────────────────────────────────────────────
-- projects
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "projects_select_published_or_own_or_admin"
  ON public.projects FOR SELECT TO authenticated
  USING (
    status = 'published'
    OR mentor_id = (SELECT auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "projects_insert_approved_mentor"
  ON public.projects FOR INSERT TO authenticated
  WITH CHECK (
    mentor_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.mentor_profiles
       WHERE user_id = (SELECT auth.uid())
         AND verification_status = 'approved'
    )
  );

CREATE POLICY "projects_update_own_or_admin"
  ON public.projects FOR UPDATE TO authenticated
  USING      (mentor_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (mentor_id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "projects_delete_admin"
  ON public.projects FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- project_skills
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "project_skills_select_authenticated"
  ON public.project_skills FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "project_skills_insert_mentor_or_admin"
  ON public.project_skills FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "project_skills_delete_mentor_or_admin"
  ON public.project_skills FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

-- ────────────────────────────────────────────────────────────────
-- project_stages
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "project_stages_select_authenticated"
  ON public.project_stages FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "project_stages_insert_mentor_or_admin"
  ON public.project_stages FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "project_stages_update_mentor_or_admin"
  ON public.project_stages FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "project_stages_delete_mentor_or_admin"
  ON public.project_stages FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.projects
       WHERE id = project_id
         AND mentor_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

-- ────────────────────────────────────────────────────────────────
-- teams (v4.0)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "teams_select_member_or_admin"
  ON public.teams FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_members
       WHERE team_id = id AND user_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "teams_insert_own"
  ON public.teams FOR INSERT TO authenticated
  WITH CHECK (created_by = (SELECT auth.uid()));

CREATE POLICY "teams_update_lead_or_admin"
  ON public.teams FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_members
       WHERE team_id = id
         AND user_id = (SELECT auth.uid())
         AND role    = 'lead'
    )
    OR public.is_admin()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.team_members
       WHERE team_id = id
         AND user_id = (SELECT auth.uid())
         AND role    = 'lead'
    )
    OR public.is_admin()
  );

CREATE POLICY "teams_delete_admin"
  ON public.teams FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- team_members (v4.0)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "team_members_select_member_or_admin"
  ON public.team_members FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.team_members tm2
       WHERE tm2.team_id = team_id
         AND tm2.user_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "team_members_insert_self"
  ON public.team_members FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "team_members_delete_lead_or_self"
  ON public.team_members FOR DELETE TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.team_members tm2
       WHERE tm2.team_id = team_id
         AND tm2.user_id = (SELECT auth.uid())
         AND tm2.role    = 'lead'
    )
    OR public.is_admin()
  );

-- ────────────────────────────────────────────────────────────────
-- project_enrollments
-- SELECT: student, mentor, team members, or admin
-- INSERT: student only (payment_status written by backend service_role)
-- UPDATE: participants or admin (protected cols guarded by trigger)
-- DELETE: admin only
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "enrollments_select_participant_or_admin"
  ON public.project_enrollments FOR SELECT TO authenticated
  USING (
    student_id = (SELECT auth.uid())
    OR mentor_id = (SELECT auth.uid())
    OR public.is_team_member(id)
    OR public.is_admin()
  );

CREATE POLICY "enrollments_insert_student"
  ON public.project_enrollments FOR INSERT TO authenticated
  WITH CHECK (student_id = (SELECT auth.uid()));

CREATE POLICY "enrollments_update_participant_or_admin"
  ON public.project_enrollments FOR UPDATE TO authenticated
  USING (
    student_id = (SELECT auth.uid())
    OR mentor_id = (SELECT auth.uid())
    OR public.is_team_member(id)
    OR public.is_admin()
  )
  WITH CHECK (
    student_id = (SELECT auth.uid())
    OR mentor_id = (SELECT auth.uid())
    OR public.is_team_member(id)
    OR public.is_admin()
  );

CREATE POLICY "enrollments_delete_admin"
  ON public.project_enrollments FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- stage_progress
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "stage_progress_select_participant_or_admin"
  ON public.stage_progress FOR SELECT TO authenticated
  USING (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

CREATE POLICY "stage_progress_insert_participant_or_admin"
  ON public.stage_progress FOR INSERT TO authenticated
  WITH CHECK (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

CREATE POLICY "stage_progress_update_participant_or_admin"
  ON public.stage_progress FOR UPDATE TO authenticated
  USING (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  )
  WITH CHECK (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

-- ────────────────────────────────────────────────────────────────
-- messages
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "messages_select_participant_or_admin"
  ON public.messages FOR SELECT TO authenticated
  USING (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

CREATE POLICY "messages_insert_participant_as_sender"
  ON public.messages FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND public.is_enrollment_participant(enrollment_id)
  );

CREATE POLICY "messages_update_participant"
  ON public.messages FOR UPDATE TO authenticated
  USING      (public.is_enrollment_participant(enrollment_id))
  WITH CHECK (public.is_enrollment_participant(enrollment_id));

CREATE POLICY "messages_delete_admin"
  ON public.messages FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- disputes
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "disputes_select_participant_or_admin"
  ON public.disputes FOR SELECT TO authenticated
  USING (
    public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

CREATE POLICY "disputes_insert_participant"
  ON public.disputes FOR INSERT TO authenticated
  WITH CHECK (
    raised_by = (SELECT auth.uid())
    AND public.is_enrollment_participant(enrollment_id)
  );

CREATE POLICY "disputes_update_admin"
  ON public.disputes FOR UPDATE TO authenticated
  USING      (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "disputes_delete_admin"
  ON public.disputes FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- posts
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "posts_select_visible_or_own_or_admin"
  ON public.posts FOR SELECT TO authenticated
  USING (
    is_deleted = false
    OR author_id = (SELECT auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "posts_insert_own"
  ON public.posts FOR INSERT TO authenticated
  WITH CHECK (author_id = (SELECT auth.uid()));

CREATE POLICY "posts_update_own_or_admin"
  ON public.posts FOR UPDATE TO authenticated
  USING      (author_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (author_id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "posts_delete_own_or_admin"
  ON public.posts FOR DELETE TO authenticated
  USING (author_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- post_hashtags
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "post_hashtags_select_authenticated"
  ON public.post_hashtags FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "post_hashtags_insert_own_post"
  ON public.post_hashtags FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.posts
       WHERE id = post_id
         AND author_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

CREATE POLICY "post_hashtags_delete_own_post_or_admin"
  ON public.post_hashtags FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.posts
       WHERE id = post_id
         AND author_id = (SELECT auth.uid())
    )
    OR public.is_admin()
  );

-- ────────────────────────────────────────────────────────────────
-- comments
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "comments_select_visible_or_own_or_admin"
  ON public.comments FOR SELECT TO authenticated
  USING (
    is_deleted = false
    OR author_id = (SELECT auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "comments_insert_own"
  ON public.comments FOR INSERT TO authenticated
  WITH CHECK (author_id = (SELECT auth.uid()));

CREATE POLICY "comments_update_own_or_admin"
  ON public.comments FOR UPDATE TO authenticated
  USING      (author_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (author_id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "comments_delete_own_or_admin"
  ON public.comments FOR DELETE TO authenticated
  USING (author_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- likes
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "likes_select_authenticated"
  ON public.likes FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "likes_insert_own"
  ON public.likes FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "likes_delete_own"
  ON public.likes FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ────────────────────────────────────────────────────────────────
-- bookmarks (private to owner)
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "bookmarks_select_own"
  ON public.bookmarks FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE POLICY "bookmarks_insert_own"
  ON public.bookmarks FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "bookmarks_delete_own"
  ON public.bookmarks FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ────────────────────────────────────────────────────────────────
-- follows
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "follows_select_authenticated"
  ON public.follows FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "follows_insert_own"
  ON public.follows FOR INSERT TO authenticated
  WITH CHECK (follower_id = (SELECT auth.uid()));

CREATE POLICY "follows_delete_own"
  ON public.follows FOR DELETE TO authenticated
  USING (follower_id = (SELECT auth.uid()));

-- ────────────────────────────────────────────────────────────────
-- notifications
-- INSERT is only via SECURITY DEFINER functions — bypasses RLS entirely.
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "notifications_select_own"
  ON public.notifications FOR SELECT TO authenticated
  USING (recipient_id = (SELECT auth.uid()));

CREATE POLICY "notifications_update_own"
  ON public.notifications FOR UPDATE TO authenticated
  USING      (recipient_id = (SELECT auth.uid()))
  WITH CHECK (recipient_id = (SELECT auth.uid()));

CREATE POLICY "notifications_delete_own"
  ON public.notifications FOR DELETE TO authenticated
  USING (recipient_id = (SELECT auth.uid()));

-- ────────────────────────────────────────────────────────────────
-- rank_history — IMMUTABLE ledger
-- No INSERT/UPDATE/DELETE for authenticated. award_rank_points() writes only.
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "rank_history_select_own_or_admin"
  ON public.rank_history FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- resale_listings
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "resale_listings_select_live_or_own_or_admin"
  ON public.resale_listings FOR SELECT TO authenticated
  USING (
    (admin_approved = true AND status = 'listed')
    OR seller_id = (SELECT auth.uid())
    OR public.is_admin()
  );

CREATE POLICY "resale_listings_insert_completed_enrollment"
  ON public.resale_listings FOR INSERT TO authenticated
  WITH CHECK (
    seller_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.project_enrollments
       WHERE id         = enrollment_id
         AND student_id = (SELECT auth.uid())
         AND status     = 'completed'
    )
  );

CREATE POLICY "resale_listings_update_seller_or_admin"
  ON public.resale_listings FOR UPDATE TO authenticated
  USING      (seller_id = (SELECT auth.uid()) OR public.is_admin())
  WITH CHECK (seller_id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "resale_listings_delete_admin"
  ON public.resale_listings FOR DELETE TO authenticated
  USING (public.is_admin());

-- ────────────────────────────────────────────────────────────────
-- resale_purchases
-- ────────────────────────────────────────────────────────────────
CREATE POLICY "resale_purchases_select_own_or_admin"
  ON public.resale_purchases FOR SELECT TO authenticated
  USING (buyer_id = (SELECT auth.uid()) OR public.is_admin());

CREATE POLICY "resale_purchases_insert_own"
  ON public.resale_purchases FOR INSERT TO authenticated
  WITH CHECK (buyer_id = (SELECT auth.uid()));

-- ================================================================
-- 8. GRANTS
--
-- Order is critical:
--   1. Strip anon from all tables + sequences.
--   2. Grant broad access to authenticated (RLS controls row scope).
--   3. Grant service_role full access.
--   4. Set default privileges for all future objects.
--   5. Grant specific functions to authenticated.
--   6. REVOKE sensitive functions from authenticated AFTER all grants.
--      (Must be last so a later GRANT ALL cannot re-add them.)
-- ================================================================

-- Step 1: Strip anon from all tables and sequences
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- Step 2: Grant authenticated standard table access (RLS enforces row scope)
GRANT USAGE                          ON SCHEMA public          TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Step 3: service_role full access (needed by Edge Functions + adminSupabase)
GRANT USAGE                          ON SCHEMA public          TO service_role;
GRANT ALL                            ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL                            ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- Step 4: Default privileges — applies to all FUTURE tables/sequences/functions
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT                  ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL                            ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL                            ON SEQUENCES  TO service_role;

-- Step 5: Function-level grants to authenticated
GRANT EXECUTE ON FUNCTION public.get_current_user_role()             TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin()                          TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_team_member(uuid)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_enrollment_participant(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_stage(uuid, text)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_project(uuid)              TO authenticated;

-- Step 6: REVOKE sensitive functions from authenticated + anon
-- These are ONLY callable by service_role or other SECURITY DEFINER functions.
-- This REVOKE must come AFTER all grants so it is not overridden.
REVOKE EXECUTE ON FUNCTION public.award_rank_points(uuid, integer, text, uuid)
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.award_team_stage_points(uuid, integer, text, uuid)
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.initialize_stage_progress(uuid)
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.update_updated_at()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.increment_post_counters()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.update_guild_member_count()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.update_enrollment_count()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.update_repost_counter()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.prevent_sensitive_enrollment_update()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.notify_github_stage_submit()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.notify_github_stage_approve()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.notify_github_stage_changes()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.notify_github_mentor_added()
  FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.notify_github_username_set()
  FROM authenticated, anon;

-- ================================================================
-- 9. SEED DATA — Default Guilds
-- ================================================================
INSERT INTO public.guilds (name, slug, description, is_active)
VALUES
  ('React Artisans',      'react-artisans',      'Frontend & mobile developers — React, Next.js, React Native',  true),
  ('Python Wizards',      'python-wizards',       'Backend & data engineers — Django, Flask, Data Science',       true),
  ('Android Hunters',     'android-hunters',      'Android developers — Kotlin, Jetpack Compose',                 true),
  ('iOS Crafters',        'ios-crafters',         'iOS developers — Swift, SwiftUI',                              true),
  ('DevOps Warriors',     'devops-warriors',      'Infrastructure engineers — Docker, Kubernetes, CI/CD',         true),
  ('Data Alchemists',     'data-alchemists',      'ML/AI practitioners — Machine Learning, AI, Data Engineering', true),
  ('Full Stack Heroes',   'full-stack-heroes',    'Full stack developers — MERN, MEAN, JAMstack',                 true),
  ('Cloud Architects',    'cloud-architects',     'Cloud & infrastructure engineers — AWS, Azure, GCP',           true),
  ('Blockchain Pioneers', 'blockchain-pioneers',  'Web3 developers — Smart Contracts, Solidity',                  true),
  ('Game Smiths',         'game-smiths',          'Game developers — Unity, Unreal Engine',                       true);

-- ================================================================
-- END OF SCHEMA — SKILLIMA v4.0
--
-- SUMMARY OF OBJECTS CREATED:
--   Extensions  : 3  (pgcrypto, pg_trgm, unaccent)
--   ENUM types  : 18 (includes team_role)
--   Tables      : 28 (includes teams, team_members)
--   Indexes     : 61 (B-tree, GIN trigram, partial, unique)
--   Functions   : 21 (all with SET search_path = '')
--   Triggers    : 24 (updated_at × 13, auth × 1, counters × 5, github × 5)
--   RLS policies: 96 (all 28 tables, per-operation, no FOR ALL)
--   Seed rows   : 10 guilds
--
-- AFTER DEPLOYING, set DB config vars in Supabase Dashboard:
--   ALTER DATABASE postgres SET app.supabase_url       = 'https://xxxx.supabase.co';
--   ALTER DATABASE postgres SET app.service_role_key   = 'eyJ...';
-- These are read by the GitHub trigger functions (5.17–5.21).
-- ================================================================