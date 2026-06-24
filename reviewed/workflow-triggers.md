# GitHub Actions Workflow Triggers

> How each workflow triggers — automatically and manually.

---

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   git push (main)                                                   │
│       │                                                             │
│       ├── application/** changed?                                   │
│       │       │                                                     │
│       │      YES ──► "Build and Push Image" (auto)                  │
│       │                    │                                        │
│       │               on success                                    │
│       │                    │                                        │
│       │                    ▼                                        │
│       │              "Deploy to ACA" (auto)                         │
│       │                                                             │
│       ├── terraform/** changed?                                     │
│       │       │                                                     │
│       │       NO auto-trigger (manual only)                         │
│       │                                                             │
│       └── other files changed (docs, scripts, etc.)                 │
│               │                                                     │
│               NO workflows triggered                                │
│                                                                     │
│                                                                     │
│   Manual triggers (workflow_dispatch) ──────────────────────────┐   │
│       │                                                         │   │
│       ├── "Provision Azure Infrastructure"  (always manual)     │   │
│       ├── "Build and Push Image"            (also manual)       │   │
│       └── "Deploy to ACA"                   (also manual)       │   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. Provision Azure Infrastructure (`infra.yml`)

**Trigger: Manual only (`workflow_dispatch`)**

This workflow is NEVER triggered automatically. Infrastructure changes are intentional and require human approval.

| Input | Options | Purpose |
|---|---|---|
| `environment` | `dev` | Which tfvars file to use |
| `action` | `plan`, `apply`, `destroy`, `import` | What Terraform does |

### When to run

| Scenario | Action |
|---|---|
| First time setup | `import` (if resources exist) then `apply` |
| Adding/changing infrastructure | `plan` first, then `apply` |
| Tearing down environment | `destroy` |
| Reviewing what would change | `plan` |

### What triggers it

```
Nothing automatic. Always go to:
  Actions > "Provision Azure Infrastructure" > Run workflow
```

---

## 2. Build and Push Image (`build.yml`)

**Trigger: Automatic on push + Manual**

### Automatic trigger

```yaml
on:
  push:
    branches: [main]
    paths:
      - "application/**"
```

Any push to `main` that changes files under `application/` triggers this workflow. This includes:

| Change | Triggers build? |
|---|---|
| `application/src/**/*.java` | YES |
| `application/src/main/resources/application.yml` | YES |
| `application/src/main/resources/db/migration/*.sql` | YES |
| `application/pom.xml` | YES |
| `application/Dockerfile` | YES |
| `terraform/*.tf` | NO |
| `README.md` | NO |
| `.github/workflows/deploy.yml` | NO |
| `reviewed/*.md` | NO |

### Manual trigger

```
Actions > "Build and Push Image" > Run workflow
```

No inputs required. Builds from the latest `main` branch code.

### What it does

1. Checks out code
2. Logs into Azure (OIDC)
3. Sets up JDK 21
4. Runs `mvn clean package -DskipTests`
5. Logs into ACR
6. Builds Docker image
7. Pushes with two tags: `orders-service:<short-sha>` and `orders-service:latest`

---

## 3. Deploy to ACA (`deploy.yml`)

**Trigger: Automatic after build + Manual**

### Automatic trigger

```yaml
on:
  workflow_run:
    workflows: ["Build and Push Image"]
    types: [completed]
    branches: [main]
```

This runs automatically when `Build and Push Image` **completes** (success or failure). The deploy job has a condition that only proceeds on success:

```yaml
if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
```

### Manual trigger

```
Actions > "Deploy to ACA" > Run workflow
```

| Input | Options | Purpose |
|---|---|---|
| `image_tag` | Any full image tag (optional) | Deploy a specific version. Empty = use `latest` |
| `fresh_deploy` | `false`, `true` | `true` = delete and recreate the container app (use when stuck) |

### What it does

1. Logs into Azure (OIDC)
2. Gets the MI Client ID from Azure
3. **If `fresh_deploy: true`**: deletes existing app, creates new one with all config
4. **If `fresh_deploy: false`**: waits for provisioning, then updates image + env vars
5. Verifies deployment
6. Prints the app URL

---

## Complete Trigger Chain

### Scenario A: Application code change (most common)

```
Developer pushes Java/SQL/config change to main
    │
    ▼
"Build and Push Image" triggers automatically
  (because application/** changed)
    │
    ▼ (on success)
"Deploy to ACA" triggers automatically
  (because workflow_run: Build and Push Image completed)
    │
    ▼
New image is live on Container App
```

**Developer action required: just `git push`**

### Scenario B: Infrastructure change

```
Developer modifies terraform/*.tf files and pushes to main
    │
    ▼
NO automatic workflow triggers
    │
    ▼
Developer manually runs "Provision Azure Infrastructure"
  with action: plan (review) then apply (execute)
```

**Developer action required: `git push` + manual workflow run**

### Scenario C: Documentation or workflow change

```
Developer modifies README.md, .github/workflows/*.yml, docs, etc.
    │
    ▼
NO automatic workflow triggers
```

**No action required**

### Scenario D: Fix a stuck deployment

```
Container app is stuck in Failed/InProgress state
    │
    ▼
Developer manually runs "Deploy to ACA"
  with fresh_deploy: true
    │
    ▼
Old app deleted, new app created from scratch
```

**Developer action required: manual workflow run with `fresh_deploy: true`**

---

## Summary Table

| Workflow | Auto trigger | Manual trigger | Depends on |
|---|---|---|---|
| **Infra** | Never | Always | — |
| **Build** | Push to `main` when `application/**` changes | Yes | — |
| **Deploy** | After Build completes successfully | Yes | Build (for auto) |

---

## GitHub Secrets Required by All Workflows

| Secret | Used by |
|---|---|
| `AZURE_CLIENT_ID` | All three workflows |
| `AZURE_TENANT_ID` | All three workflows |
| `AZURE_SUBSCRIPTION_ID` | All three workflows |
| `ACR_NAME` | Build, Deploy |