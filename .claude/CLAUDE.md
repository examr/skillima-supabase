# Supabase Monorepo

pnpm 10 + Turborepo monorepo. Requires Node >= 22.

## Structure

| Directory           | Purpose                                                       |
| ------------------- | ------------------------------------------------------------- |
| `apps/studio`       | Supabase Studio/Dashboard — Next.js (pages router), React 18  |
| `apps/docs`         | Documentation site                                            |
| `apps/www`          | Marketing website                                             |
| `packages/ui`       | Shared UI components (shadcn/ui based)                        |
| `packages/ui-patterns` | Composed UI patterns (Admonition, AssistantChat, CommandMenu, etc.) |
| `packages/common`   | Shared utilities, feature flags, auth, telemetry              |
| `packages/ai-commands` | AI command definitions                                     |
| `packages/pg-meta`  | PostgreSQL metadata utilities                                 |
| `packages/shared-data` | Shared static data/constants                              |
| `e2e/studio`        | Playwright E2E tests for Studio                               |

## Common Commands

```bash
pnpm install                          # install dependencies
pnpm dev:studio                       # run Studio dev server
pnpm test:studio                      # run Studio unit tests (vitest)
pnpm --prefix e2e/studio run e2e       # run Studio E2E tests (playwright)
pnpm build --filter=studio             # build Studio
pnpm lint --filter=studio              # lint Studio
pnpm typecheck                        # typecheck all packages
```

---

## Studio Deep Dive (`apps/studio`)

Next.js **pages router** (not app router). React 18, TypeScript strict mode.

### Directory Layout

```
apps/studio/
├── pages/                  # Next.js pages — route = file path
│   ├── _app.tsx            # App shell: providers, global styles
│   ├── _document.tsx       # HTML document
│   ├── project/[ref]/      # Project-scoped pages
│   │   ├── database/       # Tables, functions, triggers, etc.
│   │   ├── auth/           # Auth settings
│   │   ├── storage/        # Storage browser
│   │   ├── logs/           # Log explorer
│   │   └── ...
│   ├── org/[slug]/         # Org-scoped pages
│   └── account/            # User account pages
├── components/
│   ├── interfaces/         # Feature-specific UI (one dir per domain)
│   ├── layouts/            # Layout wrappers per section
│   ├── ui/                 # Generic local UI components
│   └── ui-patterns/        # Local composed patterns (Dialogs only)
├── data/                   # TanStack Query hooks + fetchers, grouped by domain
├── hooks/
│   ├── misc/               # Domain/business hooks
│   ├── ui/                 # UI-only hooks
│   └── analytics/          # Tracking hooks
├── state/                  # Valtio global state stores
├── lib/                    # Pure utilities (no React)
│   ├── constants/          # IS_PLATFORM, API_URL, PROJECT_STATUS, etc.
│   ├── auth.tsx            # Auth context/provider
│   ├── helpers.ts          # General helpers
│   └── ...
└── types/                  # Shared TypeScript types
```

### TypeScript Path Aliases

```
@/*        → apps/studio/* (e.g., @/data/..., @/hooks/..., @/lib/...)
@ui/*      → packages/ui/src/*
```

Import workspace packages by name: `'ui'`, `'ui-patterns'`, `'common'`, `'api-types'`, `'dev-tools'`.

---

## Data Fetching Pattern

All server state uses **TanStack Query v5** + **openapi-fetch** (`@/data/fetchers`).

### Naming Conventions

| File suffix | Purpose |
|---|---|
| `*-query.ts` | `useXxxQuery` — read data |
| `*-mutation.ts` | `useXxxMutation` — write data |
| `keys.ts` | Query key factories per domain |

### Template

```ts
// data/database/backups-query.ts
import { useQuery } from '@tanstack/react-query'
import { get, handleError } from '@/data/fetchers'
import { databaseKeys } from './keys'
import type { ResponseError, UseCustomQueryOptions } from '@/types'

export async function getBackups({ projectRef }: { projectRef?: string }, signal?: AbortSignal) {
  if (!projectRef) throw new Error('Project ref is required')
  const { data, error } = await get(`/platform/database/{ref}/backups`, {
    params: { path: { ref: projectRef } },
    signal,
  })
  if (error) handleError(error)
  return data
}

export type BackupsData = Awaited<ReturnType<typeof getBackups>>
export type BackupsError = ResponseError

export const useBackupsQuery = <TData = BackupsData>(
  { projectRef }: { projectRef?: string },
  options: UseCustomQueryOptions<BackupsData, BackupsError, TData> = {}
) =>
  useQuery({
    queryKey: databaseKeys.backups(projectRef),
    queryFn: ({ signal }) => getBackups({ projectRef }, signal),
    enabled: !!projectRef,
    ...options,
  })
```

**QueryClient defaults**: `staleTime: 60s`. No retry on 4xx (except 429). Configured in `data/query-client.ts`.

---

## State Management

### Server state → TanStack Query

### Client/UI state → Valtio (`state/`)

All Valtio stores follow:

```ts
import { proxy, useSnapshot } from 'valtio'

export const fooState = proxy({ value: '', setValue: (v: string) => { fooState.value = v } })
export const useFooStateSnapshot = () => useSnapshot(fooState)
```

Stores in `state/`:

| Store | Purpose |
|---|---|
| `app-state.ts` | Sidebar visibility, docs panel, MFA, branch modal |
| `sql-editor-v2.ts` | SQL editor tabs and state |
| `table-editor.tsx` | Table editor selection |
| `ai-assistant-state.tsx` | AI assistant panel |
| `side-panels.ts` | Slide-over panels |
| `tabs.tsx` | Global tab manager |

---

## Component Architecture

### Layouts (`components/layouts/`)

Every section has a layout wrapper (e.g., `DatabaseLayout`, `ProjectLayout`). Pages import and use their layout via `getLayout` pattern.

### Interface Components (`components/interfaces/`)

One directory per product domain. Co-locate sub-components with their parent — no separate sub-component directories. Avoid barrel re-export files.

Domain directories include: `Auth`, `Database`, `SQLEditor`, `Storage`, `TableGridEditor`, `Billing`, `Organization`, `Branching`, `EdgeFunctions`, `Realtime`, `Settings`, `Reports`, `UnifiedLogs`, etc.

### UI Hierarchy

1. `'ui'` package — primitives (Button, Input, Dialog, etc.) — always check here first
2. `'ui-patterns'` package — composed patterns (Admonition, AssistantChat, CommandMenu, ComplexTabs, FilterBar, GlassPanel, etc.)
3. `components/ui/` — Studio-local generic components
4. `components/ui-patterns/Dialogs/` — Studio-local dialog patterns

**Deprecated**: `<InformationBox>` → use `<Admonition>` from `'ui-patterns'`.

---

## UI Conventions

- **Tailwind only** — semantic tokens (`bg-muted`, `text-foreground-light`, `border-default`), no hardcoded colors.
- Import UI primitives from `'ui'`. Use `_Shadcn_`-suffixed variants for form primitives.
- Check `packages/ui/index.tsx` before creating new primitives.
- Icons from `lucide-react` or `@heroicons/react`.
- **U.S. English** everywhere in copy.

---

## Feature Flags

Feature flags come from two sources, both surfaced via `packages/common/feature-flags.tsx`:

| Source | Hook | Scope |
|---|---|---|
| ConfigCat | `useFlag('flagName')` | Boolean flags for all users |
| PostHog | `useIsFeatureEnabled('flag')` | Targeting/percentage rollouts |

Gate new features behind a flag. Use `IS_PLATFORM` from `@/lib/constants` to guard platform-only code (vs. self-hosted).

---

## Permissions

Use `useCheckPermissions` hook (`hooks/misc/useCheckPermissions.ts`):

```ts
const canUpdateTable = useCheckPermissions(PermissionAction.TENANT_SQL_ADMIN_WRITE, 'tables')
```

Permissions are evaluated via json-logic conditions fetched from the API.

---

## Key Constants (`lib/constants/`)

| Constant | Value |
|---|---|
| `IS_PLATFORM` | `true` when running on Supabase cloud |
| `API_URL` | Base API URL (auto-resolved) |
| `PG_META_URL` | pg-meta service URL |
| `DATETIME_FORMAT` | `'DD MMM YYYY, HH:mm:ss (ZZ)'` — use for all dayjs formatting |
| `PROJECT_STATUS` | Enum of project lifecycle states |
| `DOCS_URL` | Docs base URL |

---

## Testing

**Unit tests**: Vitest + jsdom + React Testing Library. Co-locate test files (`*.test.ts` / `*.test.tsx`).

```bash
pnpm test:studio           # run all unit tests
pnpm test:studio -- --watch  # watch mode
```

Setup files: `tests/setup/polyfills.ts`, `tests/vitestSetup.ts`, `tests/setup/radix.js`.

Coverage targets `lib/**/*.ts` only.

**E2E tests**: Playwright in `e2e/studio/`.

```bash
pnpm --prefix e2e/studio run e2e
```

---

## AI / MCP Integration

Studio has first-class AI features:

- `state/ai-assistant-state.tsx` — AI assistant panel state
- `components/interfaces/SQLEditor/AskAIWidget.tsx` — inline SQL AI
- `lib/ai/` — AI utilities
- `@ai-sdk/react`, `@ai-sdk/openai`, `@modelcontextprotocol/sdk` — AI SDK dependencies
- `@supabase/mcp-server-supabase` — MCP server integration

---

## Sentry + Observability

- Sentry configured via `sentry.server.config.ts` / `sentry.edge.config.ts`
- Instrumentation via `instrumentation.ts` / `instrumentation-client.ts`
- PostHog for analytics/telemetry (`lib/posthog.ts`, `packages/common/posthog-client.ts`)

---

## Key Dependencies

| Package | Purpose |
|---|---|
| `@tanstack/react-query` | Server state management |
| `valtio` | Client state management |
| `openapi-fetch` | Type-safe API client (generated from OpenAPI spec) |
| `@monaco-editor/react` | SQL / code editors |
| `react-data-grid` | High-performance data grid (Table Editor) |
| `@dnd-kit/*` | Drag-and-drop |
| `dayjs` | Date/time formatting |
| `nuqs` | URL search param state |
| `zod` + `@hookform/resolvers` | Form validation |
| `react-hook-form` | Forms |
| `reactflow` | Flow diagram (ExplainVisualizer) |
| `@graphiql/react` | GraphQL explorer |
| `@stripe/react-stripe-js` | Billing UI |

---

## Code Review Graph (MCP)

This project has a knowledge graph via `code-review-graph` MCP tools. **Always use graph tools before Grep/Glob/Read** when exploring the codebase:

- `semantic_search_nodes` — find functions/components by name or concept
- `get_impact_radius` — blast radius of a change
- `query_graph` — trace callers, callees, imports, tests
- `detect_changes` — risk-scored review of recent changes
- `get_architecture_overview` — high-level structure

Fall back to Grep/Glob/Read only when the graph doesn't cover it.
