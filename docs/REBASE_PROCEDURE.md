# Chaptarr Private Mirror Rebase Procedure

## Overview

`Josh-Archer/chaptarr-private` is a **private working mirror** of [`Chaptarr/chaptarr`](https://github.com/Chaptarr/chaptarr) for homelab patches ([`Josh-Archer/home#2337`](https://github.com/Josh-Archer/home/issues/2337)).

To maintain seamless compatibility with upstream releases and prevent merge fragmentation, this repository follows strict branch and patch invariants.

---

## Branch Architecture & Invariants

```
upstream/develop (Chaptarr/chaptarr)
       │
       ▼ (exact SHA match, no local commits)
    develop
       │
       ▼ (rebased homelab patches)
  homelab/patches  ──►  .github/workflows/ghcr-publish.yml (Multi-Arch OCI Image)
```

1. **`develop` is SHA-identical to `upstream/develop`**:
   - `develop` must never contain homelab-only commits, custom documentation, or deployment artifacts.
   - It serves exclusively as the clean tracking branch of upstream development.
2. **`homelab/patches` carries homelab-specific improvements**:
   - All homelab-specific features, bugfixes, and CI workflows reside on `homelab/patches` (or scoped topic branches like `homelab/zip-extract`).
   - Current homelab patch payload:
     - **Bookshelf zip-extract and upgrade-path fixes** (`Josh-Archer/home#2336`): In-flight zip/tarball extraction for multi-format imports and typed `RootFolderNotFoundException`.
     - **ImportListSync local lookup & Hardcover cursor persistence** (`chaptarr-private#3`, `#4`): Targeted batch lookups and deferred `CommitState()` cursor persistence.
     - **Multi-arch GHCR publication workflow** (`.github/workflows/ghcr-publish.yml`): Builds and publishes multi-arch (`linux/amd64`, `linux/arm64`) container images to `ghcr.io/josh-archer/chaptarr`.
     - **Automated rebase tooling** (`scripts/rebase-upstream.sh` and `docs/REBASE_PROCEDURE.md`).
3. **Deployment Gate & Quiet Period**:
   - Do not deploy new custom images to the live homelab cluster during an active observation or quiet period (`Josh-Archer/home#2374`).
   - New images must be validated locally/in CI before updating the image digest pin in `Josh-Archer/home` (`grok-servaar/media/chaptarr/chaptarr-deployment.yaml`).

---

## Automated Synchronization (`scripts/rebase-upstream.sh`)

The repository includes a dedicated automation script for inspecting and applying upstream updates:

### 1. Check Status
Inspect upstream divergence and local patch counts without modifying branches:
```bash
./scripts/rebase-upstream.sh --check
```

### 2. Dry-Run Rebase
Simulate the upstream fetch, `develop` fast-forward, and `homelab/patches` rebase in temporary isolated branches:
```bash
./scripts/rebase-upstream.sh --dry-run
```

### 3. Apply Rebase
Fast-forward `develop` to `upstream/develop` and rebase `homelab/patches` onto the new base:
```bash
./scripts/rebase-upstream.sh --apply
```

### 4. Push to Origin
Apply the rebase and push updated branches to `origin` with lease protection:
```bash
./scripts/rebase-upstream.sh --push
```

---

## Manual Rebase Runbook

If manual execution is required or merge conflicts need interactive resolution:

### Step 1: Configure Remotes
Ensure both remotes are configured:
```bash
git remote add origin git@github.com:Josh-Archer/chaptarr-private.git 2>/dev/null || true
git remote add upstream https://github.com/Chaptarr/chaptarr.git 2>/dev/null || true
```

### Step 2: Fetch Upstream
```bash
git fetch upstream develop --tags
git fetch origin
```

### Step 3: Fast-Forward `develop`
```bash
git checkout develop
git reset --hard upstream/develop
```

### Step 4: Rebase `homelab/patches`
```bash
git checkout homelab/patches
git rebase develop
```

### Step 5: Resolve Conflicts (if any)
If conflicts occur:
1. Review conflicting files: `git status`
2. Resolve conflict markers in source files.
3. Stage resolved files: `git add <file>`
4. Continue rebase: `git rebase --continue` (or abort with `git rebase --abort`).

### Step 6: Push with Lease Protection
```bash
git push origin develop --force-with-lease
git push origin homelab/patches --force-with-lease
```

---

## Multi-Arch Image Publish & GitOps Pinning

Once `homelab/patches` is rebased and validated:

1. **Trigger Image Build**:
   - In GitHub Actions, navigate to **Publish GHCR image** (`.github/workflows/ghcr-publish.yml`).
   - Run workflow against `homelab/patches` branch.
   - Supported platforms: `linux/amd64,linux/arm64`.
   - Resulting image: `ghcr.io/josh-archer/chaptarr:<commit-sha>`.
2. **Review Image Digest**:
   - Capture the image sha256 digest from the workflow summary.
3. **Update GitOps Pin (`Josh-Archer/home`)**:
   - Update `image.digest` or `image.tag` in `grok-servaar/media/chaptarr/chaptarr-deployment.yaml`.
   - Submit a pull request to `Josh-Archer/home` with validation logs.
