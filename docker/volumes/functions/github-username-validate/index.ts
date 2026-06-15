Deno.serve(async (req: Request) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!authHeader.includes(serviceKey)) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const { userId, username } = await req.json();
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;

    const ghRes = await fetch(`https://api.github.com/users/${encodeURIComponent(username)}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "Skillima-Bot" },
    });

    await fetch(`${supabaseUrl}/rest/v1/student_profiles?user_id=eq.${userId}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${serviceKey}`,
        "apikey": serviceKey,
        "Prefer": "return=minimal",
      },
      body: JSON.stringify({
        github_username_valid: ghRes.ok ? true : ghRes.status === 404 ? false : null,
        github_username_error: ghRes.ok ? null : `GitHub username "${username}" not found.`,
      }),
    });

    return new Response(JSON.stringify({ valid: ghRes.ok }), { status: 200 });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
