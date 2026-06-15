// ─────────────────────────────────────────────────────────────────────────────
//  github-repo-complete/index.ts
//
//  Triggered by: DB trigger on project_enrollments
//                AFTER UPDATE WHERE status → 'completed'
//
//  What it does (in order):
//    1. Fetch enrollment + project + mentor + student + skills from DB
//    2. PATCH /repos/{org}/{repo}              — make repo public
//    3. PUT   /repos/.../contents/README.md   — overwrite with completion README
//    4. PUT   /repos/.../topics               — set skillima-verified + skill tags
//    5. POST  /repos/.../releases             — create certificate release
//    6. DELETE /repos/.../collaborators/{mentor} — revoke mentor access (optional)
//
//  Expected body: { "enrollmentId": "uuid" }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  ghFetch,
  repoPath,
  buildCompletionReadme,
  ok,
  err,
} from "../_shared/github.ts";

Deno.serve(async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!authHeader.includes(serviceKey)) return err("Unauthorized", 401);

    const { enrollmentId } = await req.json();
    if (!enrollmentId) return err("enrollmentId required", 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      serviceKey,
    );

    // ── 1. Fetch full context ────────────────────────────────────────────────
    const { data: enrollment, error: eErr } = await supabase
      .from("project_enrollments")
      .select(`
        id,
        student_id,
        mentor_id,
        current_stage,
        github_repo_name,
        projects (
          title,
          slug,
          difficulty,
          description,
          learning_outcomes,
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

    const repoName = enrollment.github_repo_name;
    if (!repoName) return err("Enrollment has no github_repo_name", 422);

    const project = enrollment.projects as any;
    const skills  = (project.project_skills ?? [])
      .map((ps: any) => ps.skills?.name)
      .filter(Boolean) as string[];

    // Fetch mentor profile
    const { data: mentorProfile } = await supabase
      .from("mentor_profiles")
      .select("github_username, profiles ( full_name )")
      .eq("user_id", enrollment.mentor_id)
      .single();

    // Fetch student profile
    const { data: studentProfile } = await supabase
      .from("student_profiles")
      .select("github_username")
      .eq("user_id", enrollment.student_id)
      .single();

    // ── 2. Make repo public ──────────────────────────────────────────────────
    const publicRes = await ghFetch(`${repoPath(repoName)}`, {
      method: "PATCH",
      body:   JSON.stringify({ private: false }),
    });

    if (!publicRes.ok) {
      console.warn("Failed to make repo public:", await publicRes.text());
    }

    // ── 3. Build completion README and overwrite ─────────────────────────────
    const completionReadme = buildCompletionReadme({
      project: {
        title:             project.title,
        difficulty:        project.difficulty,
        description:       project.description,
        learning_outcomes: project.learning_outcomes,
      },
      mentor: {
        full_name: (mentorProfile as any)?.profiles?.full_name ?? "Your Mentor",
        id:        enrollment.mentor_id,
      },
      enrollment: { current_stage: enrollment.current_stage },
      skills,
    });

    const readmeBase64 = btoa(unescape(encodeURIComponent(completionReadme)));

    // Get existing README SHA so we can update it
    const getReadmeRes  = await ghFetch(`${repoPath(repoName)}/contents/README.md`);
    const existingReadme = await getReadmeRes.json();

    const updateReadmeRes = await ghFetch(
      `${repoPath(repoName)}/contents/README.md`,
      {
        method: "PUT",
        body:   JSON.stringify({
          message: "🎉 Project complete — Skillima Verified",
          content: readmeBase64,
          sha:     existingReadme.sha,
        }),
      },
    );

    if (!updateReadmeRes.ok) {
      console.warn("README update failed:", await updateReadmeRes.text());
    }

    // ── 4. Set repository topics ─────────────────────────────────────────────
    // Topics must be lowercase, hyphen-separated, no spaces, max 50 chars
    const sanitize = (s: string) =>
      s.toLowerCase().replace(/[^a-z0-9-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 50);

    const topics = [
      "skillima-verified",
      sanitize(project.slug),
      ...skills.map(sanitize),
    ].filter(Boolean);

    const topicsRes = await ghFetch(`${repoPath(repoName)}/topics`, {
      method: "PUT",
      body:   JSON.stringify({ names: [...new Set(topics)] }),
    });

    if (!topicsRes.ok) {
      console.warn("Topics update failed:", await topicsRes.text());
    }

    // ── 5. Create GitHub Release (Certificate) ───────────────────────────────
    const completionDate = new Date().toLocaleDateString("en-IN", {
      day: "2-digit", month: "long", year: "numeric",
    });

    const mentorName = (mentorProfile as any)?.profiles?.full_name ?? "Mentor";

    const releaseRes = await ghFetch(`${repoPath(repoName)}/releases`, {
      method: "POST",
      body:   JSON.stringify({
        tag_name:         "skillima-certificate",
        target_commitish: "main",
        name:             `🎓 Skillima Certificate — ${project.title}`,
        body:             [
          `## Project Completion Certificate`,
          ``,
          `**Project:** ${project.title}`,
          `**Difficulty:** ${project.difficulty}`,
          `**Completed:** ${completionDate}`,
          `**Mentored by:** ${mentorName}`,
          ``,
          `This project was completed on the [Skillima](https://skillima.com) mentorship platform.`,
          `All ${enrollment.current_stage} stages were reviewed and approved by the mentor.`,
          ``,
          `**Skills demonstrated:** ${skills.join(", ")}`,
          ``,
          `---`,
          `*Verified by Skillima · [View Platform](https://skillima.com)*`,
        ].join("\n"),
        draft:      false,
        prerelease: false,
      }),
    });

    if (!releaseRes.ok) {
      console.warn("Release creation failed:", await releaseRes.text());
    } else {
      const releaseData = await releaseRes.json();
      console.log(`✅ Certificate release created: ${releaseData.html_url}`);
    }

    // ── 6. Revoke mentor collaborator access ─────────────────────────────────
    // Mentor access is revoked after completion — the repo is now public,
    // so the student's work is visible to anyone without needing collaborator access.
    if (mentorProfile?.github_username) {
      const revokeRes = await ghFetch(
        `${repoPath(repoName)}/collaborators/${mentorProfile.github_username}`,
        { method: "DELETE" },
      );
      if (!revokeRes.ok && revokeRes.status !== 404) {
        console.warn("Mentor collaborator revoke failed (non-fatal):", await revokeRes.text());
      }
    }

    // Note: We deliberately keep the student as collaborator after completion
    // so they retain write access to their own portfolio repo.

    // ── 7. Update DB: save portfolio URL ─────────────────────────────────────
    const repoUrl = `https://github.com/${Deno.env.get("GITHUB_ORG")}/${repoName}`;

    await supabase
      .from("project_enrollments")
      .update({ github_repo_url: repoUrl })
      .eq("id", enrollmentId);

    console.log(`✅ Repo completed and made public: ${repoUrl}`);

    return ok({ repoUrl, topics });

  } catch (e) {
    console.error("github-repo-complete error:", e);
    return err(e instanceof Error ? e.message : "Unknown error");
  }
});
