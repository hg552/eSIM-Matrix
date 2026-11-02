# Publishing the web app

The production app is [web.lpa.ee](https://web.lpa.ee), served by the **weblpa** Cloudflare Pages project in the **KosmoNeko** account (`a14f6861a9473561d8ca8d164c9dba74`). Its Pages production branch is `release`; the separate landing-page project is not the app deployment target.

The [Publish web release workflow](../.github/workflows/publish_web.yml) selects a published stable app tag, checks out its exact commit, builds with Flutter 3.47.2 and root base path `/`, verifies `version.json`, then deploys with pinned Wrangler to `weblpa`'s `release` branch. App code comes entirely from the public release, without a private overlay or signing material.

## Automatic events

- `release: published` handles releases created by a maintainer or a personal access token.
- Successful completion of **Build NekokoLPA2** on `release` covers releases created with `GITHUB_TOKEN`, which do not trigger another release-event workflow. The completed build and tag must identify the same commit.

Automatic runs deploy only the latest stable release. Delayed old events, drafts, prereleases and builds from forks cannot replace production. A manual run can select an older published stable tag for an intentional rollback.

## Deployment credential

The repository secret `CLOUDFLARE_PAGES_API_TOKEN` supplies a deployment token with **Account → Cloudflare Pages → Edit**, restricted to the KosmoNeko account. The account ID and project/branch names are not secrets and are fixed in the workflow. Token values belong only in GitHub's encrypted secret storage, never source files, logs or workflow inputs.

Cloudflare scopes this Pages permission by account. The token does not need DNS editing, Workers administration, signing keys or the private Kasutera repository. The existing `web.lpa.ee` custom domain and DNS stay attached to the same project.

## Deploy or retry

```sh
gh workflow run publish_web.yml --repo iebb/NekokoLPA2 --ref master \
  -f 'release_tag=v2.4.0+600'
```

Leaving `release_tag` empty selects the latest stable release. Kasutera's `./publish_web.sh [tag]` starts the same workflow. Check `https://web.lpa.ee/version.json` for the deployed version/build; the Actions run also records the Cloudflare deployment URL.
