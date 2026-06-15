// ─────────────────────────────────────────────────────────────────────────────
//  _shared/github.ts
//  Shared GitHub App helpers used across all Skillima edge functions.
//
//  Pattern: GitHub App authentication via JWT → installation token (1h TTL).
//  All API calls go through `ghFetch()` which handles auth + error surfacing.
// ─────────────────────────────────────────────────────────────────────────────

const GITHUB_API = "https://api.github.com";
const ORG        = Deno.env.get("GITHUB_ORG")!;          // e.g. "skillima"

// ── JWT generation for GitHub App auth ───────────────────────────────────────
// GitHub requires a signed JWT to request an installation token.
// The JWT must be signed with the App's RSA private key (RS256).

async function importPrivateKey(): Promise<CryptoKey> {
  const pem = Deno.env.get("GITHUB_APP_PRIVATE_KEY")!
    .replace(/\\n/g, "\n");

  const pemBody = pem
    .replace("-----BEGIN RSA PRIVATE KEY-----", "")
    .replace("-----END RSA PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const der = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function base64url(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function generateAppJWT(): Promise<string> {
  const appId = Deno.env.get("GITHUB_APP_ID")!;
  const now   = Math.floor(Date.now() / 1000);

  const header  = { alg: "RS256", typ: "JWT" };
  const payload = { iat: now - 60, exp: now + 540, iss: appId };

  const encode  = (obj: object) => base64url(new TextEncoder().encode(JSON.stringify(obj)));
  const signingInput = `${encode(header)}.${encode(payload)}`;

  const key       = await importPrivateKey();
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64url(signature)}`;
}

// Cache the installation token for up to 55 minutes (GitHub tokens last 1h)
let _cachedToken: string | null = null;
let _tokenExpiry  = 0;

export async function getInstallationToken(): Promise<string> {
  if (_cachedToken && Date.now() < _tokenExpiry) return _cachedToken;

  const installationId = Deno.env.get("GITHUB_APP_INSTALLATION_ID")!;
  const jwt = await generateAppJWT();

  const res = await fetch(
    `${GITHUB_API}/app/installations/${installationId}/access_tokens`,
    {
      method:  "POST",
      headers: {
        Authorization: `Bearer ${jwt}`,
        Accept:        "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    },
  );

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to get installation token: ${res.status} ${body}`);
  }

  const data   = await res.json();
  _cachedToken = data.token;
  _tokenExpiry = Date.now() + 55 * 60 * 1000;
  return _cachedToken!;
}

// ── Core fetch wrapper ────────────────────────────────────────────────────────

export async function ghFetch(
  path: string,
  options: RequestInit = {},
): Promise<Response> {
  const token = await getInstallationToken();

  const res = await fetch(`${GITHUB_API}${path}`, {
    ...options,
    headers: {
      Authorization:          `Bearer ${token}`,
      Accept:                 "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type":         "application/json",
      ...(options.headers ?? {}),
    },
  });

  return res;
}

// ── Repo helpers ──────────────────────────────────────────────────────────────

export { ORG };

export function repoPath(repo: string) {
  return `/repos/${ORG}/${repo}`;
}

// Get the SHA of the HEAD of a branch (needed to create a new branch from it)
export async function getBranchSHA(repo: string, branch = "main"): Promise<string> {
  const res = await ghFetch(`${repoPath(repo)}/git/ref/heads/${branch}`);
  if (!res.ok) throw new Error(`Could not get SHA for ${branch}: ${await res.text()}`);
  const data = await res.json();
  return data.object.sha;
}

// ── README builder ────────────────────────────────────────────────────────────

export interface ReadmeContext {
  project: {
    title:              string;
    difficulty:         string;
    estimated_duration: string;
    figma_url?:         string;
    resources?:         string[];
    description?:       string;
    learning_outcomes?: string[];
  };
  guild:   { name: string };
  mentor:  { full_name: string; github_username: string; id: string };
  student: { github_username: string };
  stages:  { stage_number: number; title: string; slug: string }[];
  skills:  string[];
  enrollmentId: string;
  createdAt:    string;
}

export function buildInitialReadme(ctx: ReadmeContext): string {
  const { project, guild, mentor, stages, skills, createdAt } = ctx;

  const stageRows = stages
    .map((s, i) =>
      `| ${s.stage_number} | ${s.title} | ${i === 0 ? "🟡 In Progress" : "⬜ Locked"} |`
    )
    .join("\n");

  const stageBranches = stages
    .map((s) => `  ├── stage/${s.stage_number}-${s.slug}`)
    .join("\n");

  const skillBadges = skills
    .map((s) => `\`${s}\``)
    .join("  ");

  const resources = project.resources?.length
    ? project.resources.map((r) => `- ${r}`).join("\n")
    : "_No additional resources specified._";

  const figmaSection = project.figma_url
    ? `## 🎨 Design\n\n| | |\n|---|---|\n| **Figma URL** | [Open in Figma](${project.figma_url}) |\n| **Design Status** | Use as the reference for all UI stages |\n\n> All UI implementation must match the Figma design. Deviations must be discussed with your mentor.\n`
    : "";

  return `# ${project.title}

> A guided mentorship project on [Skillima](https://skillima.com)

![Status](https://img.shields.io/badge/Status-In%20Progress-F59E0B)
![Difficulty](https://img.shields.io/badge/Difficulty-${encodeURIComponent(project.difficulty)}-6366F1)
![Guild](https://img.shields.io/badge/Guild-${encodeURIComponent(guild.name)}-10B981)

---

## 📋 Project Overview

| | |
|---|---|
| **Project** | ${project.title} |
| **Guild** | ${guild.name} |
| **Difficulty** | ${project.difficulty} |
| **Total Stages** | ${stages.length} |
| **Estimated Duration** | ${project.estimated_duration ?? "TBD"} |
| **Started** | ${createdAt} |

---

${figmaSection}

## 👨‍🏫 Mentor

| | |
|---|---|
| **Name** | ${mentor.full_name} |
| **GitHub** | [@${mentor.github_username}](https://github.com/${mentor.github_username}) |
| **Skillima Profile** | [View Profile](https://skillima.com/mentor/${mentor.id}) |
| **Response Time** | Typically within 24 hours |

---

## 🗂️ Project Stages

| Stage | Title | Status |
|---|---|---|
${stageRows}

> Stages unlock automatically after mentor approval. Do not work ahead.

---

## 🌿 Branching Strategy

\`\`\`
main (protected — Skillima App merges only)
│
${stageBranches}
\`\`\`

**Rules:**
- Never push directly to \`main\`
- Work only on the currently active \`stage/N\` branch
- Skillima opens your PR automatically when you submit a stage
- Do not merge your own PR — mentor approval triggers the merge

---

## 🛠️ Tech Stack

${skillBadges}

---

## 📎 Resources

${resources}

---

## ⚠️ Important

- This repository is **private** during the project
- On completion it will be made **public** as your portfolio artifact
- Do not share the repo URL with anyone outside the project
- All code reviews happen via Pull Requests — check your GitHub notifications

---

*Managed by [Skillima](https://skillima.com) · Created ${createdAt}*
`;
}

export function buildCompletionReadme(ctx: {
  project: {
    title:             string;
    difficulty:        string;
    description?:      string;
    learning_outcomes?: string[];
  };
  mentor:     { full_name: string; id: string };
  enrollment: { current_stage: number };
  skills:     string[];
}): string {
  const { project, mentor, enrollment, skills } = ctx;
  const date = new Date().toLocaleDateString("en-IN", {
    day: "2-digit", month: "long", year: "numeric",
  });

  const outcomes = project.learning_outcomes?.length
    ? project.learning_outcomes.map((o) => `- ${o}`).join("\n")
    : "_See project stages for details._";

  const skillBadges = skills.map((s) => `\`${s}\``).join("  ");

  return `# ${project.title}

![Skillima Verified](https://img.shields.io/badge/Skillima-Verified-4F46E5)
![Difficulty](https://img.shields.io/badge/Difficulty-${encodeURIComponent(project.difficulty)}-059669)

> Built on the [Skillima](https://skillima.com) mentorship platform.
> Mentored by **${mentor.full_name}** · Completed ${date}

---

## About This Project

${project.description ?? ""}

## What I Built

${outcomes}

## Tech Stack

${skillBadges}

## Project Stages Completed

${enrollment.current_stage} of ${enrollment.current_stage} stages approved by mentor

## Mentor

**${mentor.full_name}** — [View Skillima Profile](https://skillima.com/mentor/${mentor.id})
`;
}

// ── PR body builder ───────────────────────────────────────────────────────────

export function buildPrBody(stage: {
  stage_number:     number;
  title:            string;
  deliverables?:    string[];
  estimated_hours?: number;
  points_on_complete: number;
}): string {
  const checks = stage.deliverables?.length
    ? stage.deliverables.map((d) => `- [ ] ${d}`).join("\n")
    : "- [ ] Complete all stage requirements as per the project brief";

  return `## Stage ${stage.stage_number}: ${stage.title}

### Deliverables Checklist
${checks}

### Mentor Review Guide
- Estimated effort: ${stage.estimated_hours ?? "TBD"}h
- Points on approval: ${stage.points_on_complete}

> This PR was created automatically by [Skillima](https://skillima.com)
> Do not merge manually — use the Skillima platform to approve.`;
}

// ── Standard JSON response helpers ───────────────────────────────────────────

export function ok(data: unknown = { ok: true }): Response {
  return new Response(JSON.stringify(data), {
    status:  200,
    headers: { "Content-Type": "application/json" },
  });
}

export function err(message: string, status = 500): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
