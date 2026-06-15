// ─────────────────────────────────────────────────────────────────────────────
//  github-stage-submit/index.ts
//
//  Triggered by: DB trigger on stage_progress
//                AFTER UPDATE WHERE status → 'submitted'
//                AND github_pr_number IS NULL (no duplicate PRs)
//
//  What it does:
//    1. Fetch stage_progress → enrollment → project_stage details
//    2. POST /repos/.../pulls        — open PR: stage/N → main
//    3. PATCH stage_progress          — save PR number to DB
//
//  Expected body: { "stageProgressId": "uuid" }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  ghFetch,
  ORG,
  repoPath,
  buildPrBody,
  ok,
  err,
} from "../_shared/github.ts";

Deno.serve(async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!authHeader.includes(serviceKey)) return err("Unauthorized", 401);

    const { stageProgressId } = await req.json();
    if (!stageProgressId) return err("stageProgressId required", 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      serviceKey,
    );

    // ── 1. Fetch stage progress + related data ───────────────────────────────
    const { data: sp, error: spErr } = await supabase
      .from("stage_progress")
      .select(`
        id,
        enrollment_id,
        stage_id,
        status,
        github_pr_number,
        project_enrollments (
          github_repo_name,
          student_id,
          projects (
            id
          )
        ),
        project_stages (
          stage_number,
          title,
          slug,
          deliverables,
          estimated_hours,
          points_on_complete
        )
      `)
      .eq("id", stageProgressId)
      .single();

    if (spErr || !sp) return err(`Stage progress not found: ${spErr?.message}`, 404);
    if (sp.status !== "submitted") return ok({ skipped: "not in submitted status" });
    if (sp.github_pr_number)       return ok({ skipped: "PR already exists", pr: sp.github_pr_number });

    const enrollment = sp.project_enrollments as any;
    const stage      = sp.project_stages      as any;
    const repoName   = enrollment?.github_repo_name;

    if (!repoName) return err("Enrollment has no github_repo_name yet", 422);

    // ── 2. Build branch name ─────────────────────────────────────────────────
    const stageBranch = `stage/${stage.stage_number}-${
      stage.slug ?? stage.title.toLowerCase().replace(/\s+/g, "-")
    }`;

    // ── 3. Open PR: stage/N → main ───────────────────────────────────────────
    const prBody = buildPrBody(stage);

    const prRes = await ghFetch(`${repoPath(repoName)}/pulls`, {
      method: "POST",
      body:   JSON.stringify({
        title: `Stage ${stage.stage_number}: ${stage.title}`,
        head:  stageBranch,
        base:  "main",
        body:  prBody,
      }),
    });

    if (!prRes.ok) {
      const body = await prRes.text();
      // 422 = PR already open for this branch pair — fetch existing PR number
      if (prRes.status === 422) {
        const listRes  = await ghFetch(
          `${repoPath(repoName)}/pulls?head=${ORG}:${stageBranch}&state=open`,
        );
        const prs = await listRes.json();
        if (prs.length > 0) {
          await supabase
            .from("stage_progress")
            .update({ github_pr_number: prs[0].number })
            .eq("id", stageProgressId);
          return ok({ prNumber: prs[0].number, reused: true });
        }
      }
      return err(`Failed to open PR: ${prRes.status} ${body}`, 502);
    }

    const prData   = await prRes.json();
    const prNumber = prData.number;

    // ── 4. Save PR number to stage_progress ──────────────────────────────────
    await supabase
      .from("stage_progress")
      .update({
        github_pr_number: prNumber,
        submitted_at:     new Date().toISOString(),
      })
      .eq("id", stageProgressId);

    console.log(
      `✅ PR #${prNumber} opened for stage ${stage.stage_number} — enrollment ${sp.enrollment_id}`,
    );

    return ok({ prNumber, url: prData.html_url });

  } catch (e) {
    console.error("github-stage-submit error:", e);
    return err(e instanceof Error ? e.message : "Unknown error");
  }
});
