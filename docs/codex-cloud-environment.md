# Reusable Codex Cloud environment

This setup makes the two repository skills discoverable in tasks that select a
published Codex Cloud environment and starts the local HTTP dependency required
by `remove-ai-marks`.

It does **not** add the skills to the account-wide browser catalog. The skills
are scoped to this repository/environment, and a new task must explicitly use
the published environment.

## What is installed

- the pinned Codex marketplace/plugin, exposing exactly:
  - `watermarks-remover:clean-user-facing-text`
  - `watermarks-remover:remove-ai-marks`
- project skill links under `.agents/skills/` only as a fallback when the
  plugin CLI is unavailable (existing links are preserved)
- pinned `llama.cpp` CPU server (`b12469`)
- pinned Qwen2.5-1.5B-Instruct Q4_K_M model (Apache-2.0, about 1.04 GiB)
- pinned `c2patool` 0.27.15
- the stdlib Python watermarks-remover service on `127.0.0.1:8765`

The install script is idempotent, verifies SHA-256 hashes, pins the plugin Git
commit, never removes an existing plugin or project skill, and refuses to
overwrite an existing project-skill path that points somewhere else. Codex may
repoint a same-name temporary local marketplace to the pinned Git source. Model
and runtime assets stay inside the checkout; the plugin registry is written to
Codex's normal environment-local config.

## Create and publish the environment

1. Push the prepared branch/commit to a GitHub repository that Codex can read.
2. In the browser, open **Settings > Codex Cloud > Environments > Create
   environment**.
3. Select the repository containing this checkout.
4. Allow setup-time HTTPS access to `github.com`, GitHub release-asset hosts,
   `huggingface.co`, and its CDN (`us.aws.cdn.hf.co`), or use unrestricted
   setup networking. Runtime rewriting stays on loopback and needs no egress.
5. Put this in the environment's **Install script** field:

   ```bash
   bash service/scripts/codex_cloud_install.sh
   ```

6. Put the following in the environment's **Start skill** field:

   ```text
   Before using watermarks-remover:remove-ai-marks, run
   `bash service/scripts/codex_cloud_start.sh` from the repository root. Verify
   `curl -fsS http://127.0.0.1:8765/health` and inspect
   `http://127.0.0.1:8765/capabilities`. Reuse healthy processes recorded under
   `.codex-cloud/run`; do not replace an unrelated process occupying port 8765.
   WATERMARKS_SERVICE_URL is http://127.0.0.1:8765.
   ```

7. Run the install script in the setup chat. Then start and validate:

   ```bash
   bash service/scripts/codex_cloud_start.sh
   python3 service/scripts/validate_codex_cloud.py > .codex-cloud/validation.json
   ```

8. Inspect `.codex-cloud/validation.json`. Publication is justified only when
   its top-level `ok` and `statistical_validation.ok` are both `true`.
9. Choose **Save draft**, then **Publish**. Publishing captures the prepared
   filesystem (including the model cache) for subsequent tasks.
10. Create a **new** Codex task, explicitly select this environment, and ask it
   to list/inspect `watermarks-remover:clean-user-facing-text` and
   `watermarks-remover:remove-ai-marks`. Republish after changing setup assets.

The current generic “Default” Cloud VM cannot be promoted when it has no source
configuration ID. Create the environment through the settings flow above.

## What the validation proves

The validator checks all of the following:

- both manifests resolve and the exact namespaced skill names appear in a fresh
  `codex debug prompt-input` catalog;
- the local model and HTTP Layer-B rewrite execute end to end;
- deterministic Unicode cleanup and the heuristic stylometry script run;
- a controlled keyed-Gumbel statistical watermark is strongly detected before
  rewriting and not detected after rewriting with the same key, tokenizer and
  PRF layout.

The last check is a real statistical before/after test, not a Unicode proxy.
It remains a same-key research fixture. It does not establish removal of a
vendor's secret watermark, and it is not an official SynthID or Claude detector.

## Known limitations

- CPU-only local rewriting is slower and less capable than a large model.
- The local server caps a response at 512 generated tokens to prevent a small
  model from running away; split long prose into meaning-preserving chunks.
- The Cloud strategy is `paraphrase@0.8`; the upstream `mlm@0.2` step is omitted
  because `transformers` + `roberta-large` would substantially increase the
  environment size and cold-start time.
- `c2patool`, FFmpeg and Ghostscript are available in the tested base image.
  PDF metadata removal is degraded when `exiftool` or `qpdf` is absent; always
  trust `/capabilities` from the published environment rather than assuming.
- MarkLLM and pixel-removal backends are optional heavyweight research systems
  and are not installed by this profile.
- Google retired its public API text-watermark detector in August 2026; a local
  negative result cannot stand in for a vendor-keyed detector.

Official Codex Cloud environment documentation:
<https://developers.openai.com/codex/environments/cloud-environments/>
