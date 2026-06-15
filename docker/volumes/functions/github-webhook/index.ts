// ─────────────────────────────────────────────────────────────────────────────
//  github-webhook/index.ts
//
//  Receives ALL GitHub webhook events for the Skillima org.
//  Registered at: GitHub App settings → Webhook URL
//
//  Events handled:
//    push                       → update student last_active_date
//    pull_request.opened        → confirm stage_progress.github_pr_number
//    pull_request.closed        → log merge (approve_stage() handles DB)
//    pull_request.review_submitted → sync mentor_feedback to stage_progress
//    repository.publicized      → trigger portfolio entry creation
//    installation.deleted       → mark enrollment disputed, alert admin
//    member.added               → log collaborator acceptance
//
//  Security: every request is verified with HMAC-SHA256 against
//            GITHUB_WEBHOOK_SECRET before processing.
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ok, err } from "../_shared/github.ts";

// ── HMAC-SHA256 signature verification ───────────────────────────────────────

async function verifySignature(
  payload: string,
  signature: string | null,
): Promise<boolean> {
  if (!signature) return false;

  const secret = Deno.env.get("GITHUB_WEBHOOK_SECRET")!;
  const key    = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payload),
  );

  const expectedHex = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  const expected = `sha256=${expectedHex}`;

  // Constant-time comparison to prevent timing attacks
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return diff === 0;
}

// ── Main handler ──────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  const body      = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  const eventName = req.headers.get("x-github-event");
  const deliveryId = req.headers.get("x-github-delivery");

  // ── Verify signature — reject anything that doesn't match ────────────────
  const valid = await verifySignature(body, signature);
  if (!valid) {
    console.error(`Invalid webhook signature — delivery ${deliveryId}`);
    return err("Invalid signature", 401);
  }

  const payload = JSON.parse(body);
  const action  = payload.action as string | undefined;

  console.log(`📨 GitHub webhook: ${eventName}${action ? `.${action}` : ""} — ${deliveryId}`);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    switch (eventName) {

      // ── push: update last_active_date on student profile ─────────────────
      case "push": {
        const repoName = payload.repository?.name as string;
        const branch   = (payload.ref as string)?.replace("refs/heads/", "");

        if (!branch?.startsWith("stage/")) break;

        // Resolve repo → enrollment → student
        const { data: enrollment } = await supabase
          .from("project_enrollments")
          .select("student_id, team_id")
          .eq("github_repo_name", repoName)
          .single();

        if (!enrollment) break;

        // Update last_active_date on the student (or all team members)
        if (enrollment.team_id) {
          const { data: members } = await supabase
            .from("team_members")
            .select("user_id")
            .eq("team_id", enrollment.team_id);

          if (members?.length) {
            await supabase
              .from("student_profiles")
              .update({ last_active_date: new Date().toISOString().split("T")[0] })
              .in("user_id", members.map((m: any) => m.user_id));
          }
        } else {
          await supabase
            .from("student_profiles")
            .update({ last_active_date: new Date().toISOString().split("T")[0] })
            .eq("user_id", enrollment.student_id);
        }

        console.log(`✅ last_active_date updated for repo ${repoName} — branch ${branch}`);
        break;
      }

      // ── pull_request.opened: confirm PR number is saved ──────────────────
      case "pull_request": {
        if (action === "opened") {
          const prNumber  = payload.pull_request?.number as number;
          const repoName  = payload.repository?.name     as string;
          const branchRef = payload.pull_request?.head?.ref as string;

          if (!branchRef?.startsWith("stage/")) break;

          // Parse stage number from branch: stage/1-project-setup → 1
          const stageNumberMatch = branchRef.match(/^stage\/(\d+)/);
          if (!stageNumberMatch) break;
          const stageNumber = parseInt(stageNumberMatch[1], 10);

          const { data: enrollment } = await supabase
            .from("project_enrollments")
            .select("id, project_id")
            .eq("github_repo_name", repoName)
            .single();

          if (!enrollment) break;

          // Find the stage_progress row for this stage and enrollment
          const { data: stageProg } = await supabase
            .from("stage_progress")
            .select("id, github_pr_number, project_stages ( stage_number )")
            .eq("enrollment_id", enrollment.id)
            .is("github_pr_number", null)   // only update if not already set
            .single();

          if (stageProg && !stageProg.github_pr_number) {
            await supabase
              .from("stage_progress")
              .update({ github_pr_number: prNumber })
              .eq("id", stageProg.id);
          }

          console.log(`✅ PR #${prNumber} confirmed for stage ${stageNumber} — repo ${repoName}`);
        }

        // pull_request.closed with merged=true: log only
        // The DB state is already updated by approve_stage() RPC
        if (action === "closed" && payload.pull_request?.merged) {
          const prNumber = payload.pull_request?.number;
          const repoName = payload.repository?.name;
          console.log(`ℹ️ PR #${prNumber} merged — repo ${repoName} (DB already updated by RPC)`);
        }

        // pull_request.review_submitted: sync mentor feedback to DB
        if (action === "review_submitted") {
          const reviewBody  = payload.review?.body as string | null;
          const prNumber    = payload.pull_request?.number as number;
          const repoName    = payload.repository?.name     as string;
          const reviewState = payload.review?.state        as string; // "approved" | "changes_requested" | "commented"

          // Only sync CHANGES_REQUESTED reviews posted directly from GitHub
          // (approve_stage/changes RPC handles the Skillima-initiated ones)
          if (reviewState === "changes_requested" && reviewBody) {
            const { data: sp } = await supabase
              .from("stage_progress")
              .select("id")
              .eq("github_pr_number", prNumber)
              .single();

            if (sp) {
              await supabase
                .from("stage_progress")
                .update({ mentor_feedback: reviewBody })
                .eq("id", sp.id);
            }
          }

          console.log(`ℹ️ Review submitted (${reviewState}) — PR #${prNumber} — repo ${repoName}`);
        }

        break;
      }

      // ── repository.publicized: create portfolio entry ─────────────────────
      case "repository": {
        if (action === "publicized") {
          const repoName = payload.repository?.name    as string;
          const repoUrl  = payload.repository?.html_url as string;

          const { data: enrollment } = await supabase
            .from("project_enrollments")
            .select("id, student_id, project_id, mentor_id, team_id")
            .eq("github_repo_name", repoName)
            .single();

          if (enrollment) {
            // Update github_repo_url so portfolio page can link to it
            await supabase
              .from("project_enrollments")
              .update({ github_repo_url: repoUrl })
              .eq("id", enrollment.id);

            console.log(`✅ Portfolio URL saved: ${repoUrl} — enrollment ${enrollment.id}`);
          }
        }
        break;
      }

      // ── installation.deleted: mark enrollment disputed ────────────────────
      // This fires if someone manually uninstalls the Skillima App.
      // Since the App is installed at org level (not per-repo), this is a
      // critical event that needs immediate admin attention.
      case "installation": {
        if (action === "deleted") {
          console.error(
            `🚨 GitHub App installation DELETED — deliveryId: ${deliveryId}`,
          );

          // Find all active enrollments and mark them disputed
          const affectedRepos: string[] = (payload.repositories ?? [])
            .map((r: any) => r.name as string);

          if (affectedRepos.length > 0) {
            await supabase
              .from("project_enrollments")
              .update({ status: "disputed" })
              .in("github_repo_name", affectedRepos)
              .eq("status", "active");

            // Notify admins via notification table
            // Admin notification logic can be extended here
            console.error(
              `🚨 Marked ${affectedRepos.length} enrollments as disputed: ${affectedRepos.join(", ")}`,
            );
          }
        }
        break;
      }

      // ── member.added: log collaborator invitation accepted ────────────────
      case "member": {
        if (action === "added") {
          const login    = payload.member?.login   as string;
          const repoName = payload.repository?.name as string;
          console.log(`✅ Collaborator ${login} accepted invitation — repo ${repoName}`);
        }
        break;
      }

      default: {
        console.log(`ℹ️ Unhandled GitHub event: ${eventName} — ignored`);
      }
    }

    return ok({ received: true, event: eventName, action });

  } catch (handlerErr) {
    // Don't return 5xx to GitHub — it will retry and flood the function
    // Log the error and return 200 so GitHub marks the delivery as delivered
    console.error(`Webhook handler error (event: ${eventName}):`, handlerErr);
    return ok({ received: true, error: "Handler error — logged server-side" });
  }
});
