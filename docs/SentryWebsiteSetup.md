# Sentry Setup for the Website Side

This repo does not currently contain a website application, so this guide is a
setup playbook rather than a repo-specific implementation guide.

Use this guide if you want Sentry on:

- a marketing site
- a docs site
- a web app dashboard
- a Next.js frontend with server-rendered routes

This guide is written for someone who has never used Sentry before.

## What You Can and Cannot Do from CLI

You can do almost everything from CLI or API once you already have:

- a Sentry account
- a Sentry organization
- an auth token

The one part that is still easiest to do in the browser is the initial account
signup and first organization creation. After that, team creation, project
creation, DSN lookup, release creation, and source map upload can all be done
from the terminal.

If you want me to do the CLI steps for you later, I can, but I will need:

- your organization slug
- an auth token with the right scopes

## Recommended Project Layout

For the website side, start simple:

- one team: `splicekit`
- one project: `splicekit-website`
- use Sentry environments to separate `development`, `staging`, and `production`

Do not create separate website projects for every environment unless you have a
specific reason to do that. One project plus environments is easier to manage.

## Step 1: Create the Sentry Account and Organization

Do this in the browser once:

1. Go to `https://sentry.io/`
2. Create an account
3. Create an organization
4. Pick an organization slug

Use a stable slug. For example:

- `splicekit`

You will use that slug in the API commands below.

## Step 2: Create an Auth Token

The recommended way is to create an internal integration and copy the
organization token from there.

In Sentry:

1. Open organization settings
2. Go to `Custom Integrations`
3. Create a new internal integration
4. Give it a clear name, for example `SpliceKit CLI`
5. Grant permissions
6. Save it
7. Copy the generated token

For this workflow, give it at least:

- `org:read`
- `team:read`
- `team:write`
- `project:read`
- `project:write`
- `project:releases`

If your org has tighter permissions, you may also need:

- `org:write`

Export it in your shell:

```bash
export SENTRY_AUTH_TOKEN='sntrys_your_token_here'
export SENTRY_ORG='splicekit'
```

## Step 3: Install `sentry-cli`

On macOS, the cleanest install is Homebrew:

```bash
brew install getsentry/tools/sentry-cli
```

Or use Sentry's install script:

```bash
curl -sL https://sentry.io/get-cli/ | sh
```

Then verify:

```bash
sentry-cli --help
```

If you want `sentry-cli` to store auth locally:

```bash
sentry-cli login --auth-token "$SENTRY_AUTH_TOKEN"
```

If you do not want it stored on disk, just keep using the environment
variables and skip `login`.

## Step 4: Create the Team from CLI

Create a website team once:

```bash
export SENTRY_TEAM='splicekit'

curl "https://sentry.io/api/0/organizations/$SENTRY_ORG/teams/" \
  -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "splicekit",
    "name": "SpliceKit"
  }'
```

If the team already exists, Sentry will reject the create request. That is
fine. You only need to create it once.

To list teams and confirm the slug:

```bash
curl "https://sentry.io/api/0/organizations/$SENTRY_ORG/teams/" \
  -H "Authorization: Bearer $SENTRY_AUTH_TOKEN"
```

## Step 5: Create the Website Project from CLI

Create the website project:

```bash
export SENTRY_PROJECT='splicekit-website'

curl "https://sentry.io/api/0/teams/$SENTRY_ORG/$SENTRY_TEAM/projects/" \
  -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "splicekit-website",
    "slug": "splicekit-website",
    "default_rules": true
  }'
```

I am intentionally not hardcoding a `platform` value here. The project create
API allows you to omit it, which is safer than guessing the wrong platform
slug. The SDK you install later will still work.

To confirm the project exists:

```bash
curl "https://sentry.io/api/0/teams/$SENTRY_ORG/$SENTRY_TEAM/projects/" \
  -H "Authorization: Bearer $SENTRY_AUTH_TOKEN"
```

## Step 6: Get the Website DSN from CLI

The DSN is what your website code uses to send browser events to Sentry.

Get the project keys:

```bash
curl "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/keys/" \
  -H "Authorization: Bearer $SENTRY_AUTH_TOKEN"
```

In the JSON response, find the active key and copy its DSN value.

Keep two different things straight:

- `SENTRY_AUTH_TOKEN`: secret, for CLI/API/source map upload only
- website DSN: public, safe to expose to the browser

## Step 7: Decide Which Website Type You Have

Use one of these two paths:

### Option A: Static or Browser-Only Site

Use this if the website is mostly client-side JavaScript or a static site.

Install:

```bash
npm install @sentry/browser
```

Then initialize Sentry in your site entrypoint with:

- your DSN
- `environment`
- `release`
- `sendDefaultPii: false` unless you intentionally want IP/user data
- `tracesSampleRate: 0` at first, until error monitoring is stable

Start minimal. Get errors working before enabling tracing, replay, or feedback.

### Option B: Next.js or Fullstack Website

Use this if the website has:

- server-rendered pages
- route handlers
- server actions
- edge functions

Install:

```bash
npm install @sentry/nextjs
```

Then follow the standard file layout from Sentry's Next.js manual setup:

- `next.config.ts`
- `instrumentation-client.ts`
- `instrumentation.ts`
- `sentry.server.config.ts`
- `sentry.edge.config.ts`

For Next.js, this is the best-supported path because it gives you:

- browser error capture
- server error capture
- edge/runtime capture
- source map integration

## Step 8: Set the Website Environment Variables

For local development:

```bash
export NEXT_PUBLIC_SENTRY_DSN='https://public_key@o123456.ingest.sentry.io/1234567'
export SENTRY_ENVIRONMENT='development'
export SENTRY_ORG='splicekit'
export SENTRY_PROJECT='splicekit-website'
export SENTRY_AUTH_TOKEN='sntrys_your_token_here'
```

If the website is Vite instead of Next.js, use:

```bash
export VITE_SENTRY_DSN='https://public_key@o123456.ingest.sentry.io/1234567'
```

The exact public variable name depends on the framework:

- Next.js: `NEXT_PUBLIC_SENTRY_DSN`
- Vite: `VITE_SENTRY_DSN`
- plain static site: put the DSN directly in the config or inject it from your build system

## Step 9: Upload Website Source Maps

For JavaScript websites, source maps matter as much as dSYMs matter for the
native runtime. Without source maps, browser stack traces will be much less
useful.

If your build tool does not already have a Sentry plugin configured, the manual
CLI path is:

1. Run a production build
2. Inject Debug IDs into the built artifacts
3. Upload the built artifacts and source maps

Example:

```bash
npm run build

sentry-cli sourcemaps inject ./dist
sentry-cli sourcemaps upload ./dist
```

Do this before deployment and against the exact built files that will go live.

If you are using Next.js, the supported path is usually to wrap the Next config
with `withSentryConfig(...)` and pass:

- `org`
- `project`
- `authToken: process.env.SENTRY_AUTH_TOKEN`

That lets the Sentry integration handle source map upload for you.

## Step 10: Verify the Website Setup

Do not try to verify from the devtools console. Sentry's docs explicitly warn
that browser-console-thrown errors are sandboxed and are not a reliable test.

Instead:

1. Add a temporary button in the site that throws `new Error("Sentry Test Error")`
2. Load the site normally
3. Click the button
4. Open Sentry and confirm the issue appears in `splicekit-website`

For server-side Next.js verification:

1. Add a temporary server-side throw
2. Hit that route normally
3. Confirm the event appears

For source map verification:

1. Trigger a fresh error after source map upload
2. Open the event
3. Confirm stack frames are readable and point at original source files

## Recommended First Configuration

When you are brand new to Sentry, start with only:

- error monitoring
- environments
- source maps

Do not turn on everything at once.

Leave these off initially:

- Session Replay
- browser tracing
- user feedback widget
- logs forwarding

Once you trust the error signal and understand the event volume, add features
one by one.

## Recommended Website Tags

On the website side, useful tags are:

- `environment`
- `release`
- `build_id`
- `route`
- `app_section`
- `logged_in=true|false`

For SpliceKit specifically, I would also set:

- `product=website`
- `surface=marketing` or `surface=app`

That makes it easy to separate website issues from patcher/runtime issues.

## Privacy Defaults

For the first pass, keep this conservative:

- `sendDefaultPii: false`
- do not attach raw user documents
- do not enable replay until you understand what gets masked

If you later enable Session Replay, review masking defaults before rolling it
out broadly.

## What I Can Do for You From Here

If you want me to do the CLI/API part for you, I can create:

- the team
- the `splicekit-website` project
- the DSN lookup commands

I will need:

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`

If you want, the next step can be a copy-paste terminal sequence just for the
account you are about to use. I can give you either:

- the shortest path, or
- the safest path with explicit verification after each command.
