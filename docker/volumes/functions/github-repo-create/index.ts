// ─────────────────────────────────────────────────────────────────────────────
//  github-repo-create/index.ts
//
//  Triggered by: DB trigger on project_enrollments
//                AFTER UPDATE WHERE status → 'active'
//
//  What it does (in order):
//    1. Fetch enrollment + project + mentor + student + stages + skills from DB
//    2. POST /orgs/{org}/repos            — create private repo
//    3. PUT  /repos/.../branches/main/protection — protect main branch
//    4. PUT  /repos/.../contents/README.md       — push initial README
//    5. PUT  /repos/.../collaborators/{student}  — add student (push)
//    6. PUT  /repos/.../collaborators/{mentor}   — add mentor  (maintain)
//    7. POST /repos/.../git/refs                 — create stage/1 branch
//    8. PATCH project_enrollments                — save github_repo_name to DB
//
//  Expected body: { "enrollmentId": "uuid" }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  ghFetch,
  ORG,
  repoPath,
  getBranchSHA,
  buildInitialReadme,
  ok,
  err,
  type ReadmeContext,
} from "../_shared/github.ts";

Deno.serve(async (req: Request) => {
  try {
    // ── 0. Auth guard — only service_role may call this ─────────────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!authHeader.includes(serviceKey)) {
      return err("Unauthorized", 401);
    }

    const { enrollmentId } = await req.json();
    if (!enrollmentId) return err("enrollmentId required", 400);

    // ── 1. Fetch all data needed to create the repo ──────────────────────────
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      serviceKey,
    );

    const { data: enrollment, error: eErr } = await supabase
      .from("project_enrollments")
      .select(`
        id,
        student_id,
        mentor_id,
        project_id,
        team_id,
        created_at,
        projects (
          id,
          title,
          slug,
          difficulty,
          figma_url,
          resources,
          description,
          learning_outcomes,
          estimated_duration,
          guilds ( name ),
          project_stages (
            id,
            stage_number,
            title,
            slug,
            deliverables,
            estimated_hours,
            points_on_complete
          ),
          project_skills (
            skills ( name )
          )
        )
      `)
      .eq("id", enrollmentId)
      .single();

    if (eErr || !enrollment) {
      return err(`Enrollment not found: ${eErr?.message}`, 404);
    }

    // Fetch mentor GitHub username
    const { data: mentorProfile } = await supabase
      .from("mentor_profiles")
      .select("github_username, profiles ( full_name, id )")
      .eq("user_id", enrollment.mentor_id)
      .single();

    // Fetch student GitHub username
    const { data: studentProfile } = await supabase
      .from("student_profiles")
      .select("github_username")
      .eq("user_id", enrollment.student_id)
      .single();

    if (!mentorProfile?.github_username) {
      return err("Mentor has no GitHub username set", 422);
    }
    if (!studentProfile?.github_username) {
      return err("Student has no GitHub username set — ask them to connect GitHub first", 422);
    }

    const project = enrollment.projects as any;
    const stages  = [...(project.project_stages ?? [])].sort(
      (a: any, b: any) => a.stage_number - b.stage_number,
    );
    const skills  = (project.project_skills ?? []).map(
      (ps: any) => ps.skills?.name,
    ).filter(Boolean);

    // ── 2. Build repo name: {project-slug}-{student-github-username} ─────────
    const repoName = `${project.slug}-${studentProfile.github_username}`
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "");

    // ── 3. Create private repo ───────────────────────────────────────────────
    const createRes = await ghFetch(`/orgs/${ORG}/repos`, {
      method: "POST",
      body:   JSON.stringify({
        name:          repoName,
        description:   `${project.title} — Skillima mentorship project`,
        private:       true,
        auto_init:     true,       // creates main branch with empty commit
        has_issues:    true,
        has_projects:  false,
        has_wiki:      false,
      }),
    });

    if (!createRes.ok) {
      const body = await createRes.text();
      // 422 = repo already exists — treat as idempotent
      if (createRes.status !== 422) {
        return err(`Failed to create repo: ${createRes.status} ${body}`, 502);
      }
    }

    // ── 4. Protect main branch ───────────────────────────────────────────────
    // Only the Skillima App installation token can merge. Students cannot
    // push directly to main — they must go through a PR.
    const protectRes = await ghFetch(
      `${repoPath(repoName)}/branches/main/protection`,
      {
        method: "PUT",
        body:   JSON.stringify({
          required_status_checks:        null,
          enforce_admins:                false,
          required_pull_request_reviews: {
            required_approving_review_count: 1,
            dismiss_stale_reviews:           true,
          },
          restrictions: {
            users: [],
            teams: [],
            apps:  [Deno.env.get("GITHUB_APP_SLUG")!],  // only the Skillima App can merge
          },
        }),
      },
    );

    if (!protectRes.ok) {
      console.warn("Branch protection failed (non-fatal):", await protectRes.text());
    }

    // ── 5. Push initial README ───────────────────────────────────────────────
    const ctx: ReadmeContext = {
      project: {
        title:              project.title,
        difficulty:         project.difficulty,
        estimated_duration: project.estimated_duration ?? "",
        figma_url:          project.figma_url,
        resources:          project.resources,
        description:        project.description,
        learning_outcomes:  project.learning_outcomes,
      },
      guild:   { name: project.guilds?.name ?? "" },
      mentor:  {
        full_name:       mentorProfile.profiles?.full_name ?? "",
        github_username: mentorProfile.github_username,
        id:              enrollment.mentor_id,
      },
      student: { github_username: studentProfile.github_username },
      stages:  stages.map((s: any) => ({
        stage_number: s.stage_number,
        title:        s.title,
        slug:         s.slug ?? s.title.toLowerCase().replace(/\s+/g, "-"),
      })),
      skills,
      enrollmentId,
      createdAt: new Date(enrollment.created_at).toLocaleDateString("en-IN"),
    };

    const readmeContent = buildInitialReadme(ctx);
    const readmeBase64  = btoa(unescape(encodeURIComponent(readmeContent)));

    // GitHub auto_init creates a default README — we overwrite it
    const readmeRes = await ghFetch(
      `${repoPath(repoName)}/contents/README.md`,
      {
        method: "PUT",
        body:   JSON.stringify({
          message: "Initial commit: project setup by Skillima",
          content: readmeBase64,
        }),
      },
    );

    if (!readmeRes.ok) {
      // If it conflicts (file already exists from auto_init), get its SHA and update
      if (readmeRes.status === 409 || readmeRes.status === 422) {
        const getRes  = await ghFetch(`${repoPath(repoName)}/contents/README.md`);
        const getData = await getRes.json();
        await ghFetch(`${repoPath(repoName)}/contents/README.md`, {
          method: "PUT",
          body:   JSON.stringify({
            message: "Initial commit: project setup by Skillima",
            content: readmeBase64,
            sha:     getData.sha,
          }),
        });
      } else {
        console.warn("README push failed:", await readmeRes.text());
      }
    }

    // ── 6. Add student as collaborator (push = can commit to branches) ───────
    await ghFetch(
      `${repoPath(repoName)}/collaborators/${studentProfile.github_username}`,
      {
        method: "PUT",
        body:   JSON.stringify({ permission: "push" }),
      },
    );

    // ── 7. Add mentor as collaborator (maintain = review PRs, no admin) ──────
    await ghFetch(
      `${repoPath(repoName)}/collaborators/${mentorProfile.github_username}`,
      {
        method: "PUT",
        body:   JSON.stringify({ permission: "maintain" }),
      },
    );

    // If team enrollment — add all team members as collaborators
    if (enrollment.team_id) {
      const { data: teamMembers } = await supabase
        .from("team_members")
        .select("user_id, student_profiles ( github_username )")
        .eq("team_id", enrollment.team_id)
        .neq("user_id", enrollment.student_id); // lead already added above

      for (const member of teamMembers ?? []) {
        const username = (member as any).student_profiles?.github_username;
        if (username) {
          await ghFetch(`${repoPath(repoName)}/collaborators/${username}`, {
            method: "PUT",
            body:   JSON.stringify({ permission: "push" }),
          });
        }
      }
    }

    // ── 8. Create stage/1 branch from main ───────────────────────────────────
    const firstStage = stages[0];
    if (firstStage) {
      const mainSHA    = await getBranchSHA(repoName, "main");
      const stageBranch = `stage/${firstStage.stage_number}-${
        firstStage.slug ?? firstStage.title.toLowerCase().replace(/\s+/g, "-")
      }`;

      const branchRes = await ghFetch(`${repoPath(repoName)}/git/refs`, {
        method: "POST",
        body:   JSON.stringify({
          ref: `refs/heads/${stageBranch}`,
          sha: mainSHA,
        }),
      });

      if (!branchRes.ok) {
        console.warn("Stage/1 branch creation failed:", await branchRes.text());
      }
    }

    // ── 9. Save repo name back to DB ─────────────────────────────────────────
    await supabase
      .from("project_enrollments")
      .update({ github_repo_name: repoName })
      .eq("id", enrollmentId);

    console.log(`✅ Repo created: ${ORG}/${repoName} for enrollment ${enrollmentId}`);

    return ok({ repoName, org: ORG });

  } catch (e) {
    console.error("github-repo-create error:", e);
    return err(e instanceof Error ? e.message : "Unknown error");
  }
});
