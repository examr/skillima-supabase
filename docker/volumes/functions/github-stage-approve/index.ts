// ─────────────────────────────────────────────────────────────────────────────
//  github-stage-approve/index.ts
//
//  Triggered by: DB trigger on stage_progress
//                AFTER UPDATE WHERE status → 'approved'
//
//  What it does (in order):
//    1. Fetch stage_progress + enrollment + stage details
//    2. POST /pulls/{n}/reviews          — submit APPROVE review with feedback
//    3. PUT  /pulls/{n}/merge            — squash merge the PR
//    4. DELETE /git/refs/heads/{branch}  — delete merged stage branch
//    5. GET  /git/ref/heads/main         — get new SHA after merge
//    6. POST /git/refs                   — create stage/N+1 branch (if exists)
//
//  Expected body: { "stageProgressId": "uuid", "feedback": "string|null" }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  ghFetch,
  repoPath,
  getBranchSHA,
  ok,
  err,
} from "../_shared/github.ts";

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

    // ── 1. Fetch stage progress + full context ───────────────────────────────
    const { data: sp, error: spErr } = await supabase
      .from("stage_progress")
      .select(`
        id,
        enrollment_id,
        github_pr_number,
        project_enrollments (
          github_repo_name,
          project_id
        ),
        project_stages (
          stage_number,
          title,
          slug,
          points_on_complete,
          projects (
            id,
            project_stages (
              stage_number,
              title,
              slug
            )
          )
        )
      `)
      .eq("id", stageProgressId)
      .single();

    if (spErr || !sp) return err(`Stage progress not found: ${spErr?.message}`, 404);

    const enrollment  = sp.project_enrollments as any;
    const stage       = sp.project_stages      as any;
    const repoName    = enrollment?.github_repo_name;
    const prNumber    = sp.github_pr_number;
    const stageNumber = stage.stage_number;

    if (!repoName)  return err("No github_repo_name on enrollment", 422);
    if (!prNumber)  return err("No github_pr_number on stage_progress", 422);

    const stageBranch = `stage/${stageNumber}-${
      stage.slug ?? stage.title.toLowerCase().replace(/\s+/g, "-")
    }`;

    // ── 2. Post APPROVE review ───────────────────────────────────────────────
    const reviewRes = await ghFetch(
      `${repoPath(repoName)}/pulls/${prNumber}/reviews`,
      {
        method: "POST",
        body:   JSON.stringify({
          event: "APPROVE",
          body:  feedback
            ? `✅ Stage ${stageNumber} approved by mentor.\n\n**Feedback:**\n${feedback}`
            : `✅ Stage ${stageNumber} approved by mentor.`,
        }),
      },
    );

    if (!reviewRes.ok) {
      // Non-fatal: PR might already have a review — log and continue
      console.warn("Approve review failed:", await reviewRes.text());
    }

    // ── 3. Squash merge the PR ───────────────────────────────────────────────
    const mergeRes = await ghFetch(
      `${repoPath(repoName)}/pulls/${prNumber}/merge`,
      {
        method: "PUT",
        body:   JSON.stringify({
          merge_method:    "squash",
          commit_title:    `Stage ${stageNumber}: ${stage.title} ✅`,
          commit_message:  feedback
            ? `Mentor approved stage ${stageNumber}.\n\nFeedback: ${feedback}`
            : `Mentor approved stage ${stageNumber}.`,
        }),
      },
    );

    if (!mergeRes.ok) {
      const body = await mergeRes.text();
      // 405 = already merged or not mergeable
      if (mergeRes.status !== 405) {
        return err(`Failed to merge PR #${prNumber}: ${mergeRes.status} ${body}`, 502);
      }
      console.warn("Merge returned 405 (possibly already merged):", body);
    }

    // ── 4. Delete the merged stage branch ───────────────────────────────────
    const deleteRes = await ghFetch(
      `${repoPath(repoName)}/git/refs/heads/${stageBranch}`,
      { method: "DELETE" },
    );

    if (!deleteRes.ok && deleteRes.status !== 422) {
      console.warn("Branch delete failed (non-fatal):", await deleteRes.text());
    }

    // ── 5. Create stage/N+1 branch if it exists in the project ──────────────
    const allStages: any[] = stage.projects?.project_stages ?? [];
    const nextStage = allStages
      .sort((a: any, b: any) => a.stage_number - b.stage_number)
      .find((s: any) => s.stage_number === stageNumber + 1);

    if (nextStage) {
      try {
        const newMainSHA   = await getBranchSHA(repoName, "main");
        const nextBranch   = `stage/${nextStage.stage_number}-${
          nextStage.slug ?? nextStage.title.toLowerCase().replace(/\s+/g, "-")
        }`;

        const nextBranchRes = await ghFetch(`${repoPath(repoName)}/git/refs`, {
          method: "POST",
          body:   JSON.stringify({
            ref: `refs/heads/${nextBranch}`,
            sha: newMainSHA,
          }),
        });

        if (!nextBranchRes.ok) {
          console.warn("Next branch creation failed:", await nextBranchRes.text());
        } else {
          console.log(`✅ Created next branch: ${nextBranch}`);
        }
      } catch (branchErr) {
        console.warn("Could not create next stage branch (non-fatal):", branchErr);
      }
    } else {
      console.log(`ℹ️ Stage ${stageNumber} was the last stage — no next branch created`);
    }

    console.log(
      `✅ Stage ${stageNumber} approved and merged — PR #${prNumber} — repo ${repoName}`,
    );

    return ok({ merged: true, prNumber, nextStage: nextStage?.stage_number ?? null });

  } catch (e) {
    console.error("github-stage-approve error:", e);
    return err(e instanceof Error ? e.message : "Unknown error");
  }
});
