// ─────────────────────────────────────────────────────────────────────────────
//  github-stage-changes/index.ts
//
//  Triggered by: DB trigger on stage_progress
//                AFTER UPDATE WHERE status → 'changes_requested'
//
//  What it does:
//    1. Fetch stage_progress + enrollment + stage
//    2. POST /pulls/{n}/reviews    — submit REQUEST_CHANGES review with feedback
//    3. iteration_count is incremented by approve_stage() RPC — not here
//
//  Expected body: { "stageProgressId": "uuid", "feedback": "string|null" }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ghFetch, repoPath, ok, err } from "../_shared/github.ts";

Deno.serve(async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!authHeader.includes(serviceKey)) return err("Unauthorized", 401);

    const { stageProgressId, feedback } = await req.json();
    if (!stageProgressId) return err("stageProgressId required", 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      serviceKey,
    );

    // ── 1. Fetch stage_progress with context ─────────────────────────────────
    const { data: sp, error: spErr } = await supabase
      .from("stage_progress")
      .select(`
        id,
        enrollment_id,
        github_pr_number,
        project_enrollments (
          github_repo_name
        ),
        project_stages (
          stage_number,
          title
        )
      `)
      .eq("id", stageProgressId)
      .single();

    if (spErr || !sp) return err(`Stage progress not found: ${spErr?.message}`, 404);

    const enrollment  = sp.project_enrollments as any;
    const stage       = sp.project_stages      as any;
    const repoName    = enrollment?.github_repo_name;
    const prNumber    = sp.github_pr_number;
    const stageNumber = stage?.stage_number;

    if (!repoName) return err("No github_repo_name on enrollment", 422);
    if (!prNumber) return err("No github_pr_number — PR must be open first", 422);

    // ── 2. Post REQUEST_CHANGES review ───────────────────────────────────────
    const reviewBody = feedback
      ? `🔄 Changes requested for Stage ${stageNumber}.\n\n**Mentor feedback:**\n${feedback}\n\nPlease address the above and push new commits to your stage branch.`
      : `🔄 Changes requested for Stage ${stageNumber}. Please review the inline comments and push new commits to your stage branch.`;

    const reviewRes = await ghFetch(
      `${repoPath(repoName)}/pulls/${prNumber}/reviews`,
      {
        method: "POST",
        body:   JSON.stringify({
          event: "REQUEST_CHANGES",
          body:  reviewBody,
        }),
      },
    );

    if (!reviewRes.ok) {
      const body = await reviewRes.text();
      // GitHub won't allow the same user to re-request changes in some cases
      // Treat as non-fatal — the DB already reflects the correct status
      console.warn(
        `REQUEST_CHANGES review failed (non-fatal): ${reviewRes.status} ${body}`,
      );
      return ok({ posted: false, reason: "GitHub review API returned non-200", status: reviewRes.status });
    }

    const reviewData = await reviewRes.json();

    console.log(
      `✅ REQUEST_CHANGES posted — Stage ${stageNumber} — PR #${prNumber} — repo ${repoName}`,
    );

    return ok({ posted: true, reviewId: reviewData.id });

  } catch (e) {
    console.error("github-stage-changes error:", e);
    return err(e instanceof Error ? e.message : "Unknown error");
  }
});
