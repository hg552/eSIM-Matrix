#!/usr/bin/env node
// Writes the update feed this project publishes.
//
// The feed keeps upstream's shape so that upstream's UpdateFeed reader works
// unchanged:
//
//   { "android": { "<channel>": [ { version, build, url, download_url,
//                                    changelog, signatures: [sha1, ...] } ] } }
//
// The signatures are the APK's own signing certificates. A build signed by
// somebody else is not offered an update, so a third party cannot use the feed
// to push an APK of their own.
//
// Usage:
//   node scripts/publish_update_feed.mjs --apk <apk> --version 1.3.4 --build 134 \
//        --tag v1.3.4 [--changelog <file>] [--repo MIY-Y/eUICC-Nexus] \
//        [--channel multi] [--out update_feed.json]
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

function arg(name, fallback = null) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1 || index === process.argv.length - 1) return fallback;
  return process.argv[index + 1];
}

const apk = arg('apk');
const version = arg('version');
const build = Number(arg('build'));
const tag = arg('tag');
const changelogFile = arg('changelog');
const repo = arg('repo', 'MIY-Y/eUICC-Nexus');
const channel = arg('channel', 'multi');
const out = arg('out', 'update_feed.json');
const sdkRoot = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || '';

if (!apk || !version || !Number.isFinite(build) || !tag) {
  console.error(
    'Usage: publish_update_feed.mjs --apk <apk> --version <v> --build <n> --tag <tag> ' +
      '[--changelog <file>] [--repo owner/name] [--channel <name>] [--out <file>]',
  );
  process.exit(2);
}

function findApksigner() {
  const candidates = [];
  if (sdkRoot) {
    const buildTools = path.join(sdkRoot, 'build-tools');
    if (fs.existsSync(buildTools)) {
      for (const dir of fs.readdirSync(buildTools).sort().reverse()) {
        // On Windows the SDK ships a .bat wrapper.
        for (const name of ['apksigner', 'apksigner.bat']) {
          const exe = path.join(buildTools, dir, name);
          if (fs.existsSync(exe)) candidates.push(exe);
        }
      }
    }
  }
  return candidates[0] || null;
}

function signerSha1s(apkPath) {
  const signer = findApksigner();
  if (!signer) {
    throw new Error(
      'apksigner not found; set ANDROID_HOME to an SDK that has build-tools',
    );
  }
  const out = execFileSync(signer, ['verify', '--print-certs', apkPath], {
    encoding: 'utf8',
    shell: process.platform === 'win32',
  });
  const digests = [...out.matchAll(/certificate SHA-1 digest: ([a-fA-F0-9]+)/g)].map(
    (m) => m[1].toUpperCase(),
  );
  if (digests.length === 0) {
    throw new Error('no signing certificate found in the APK');
  }
  return [...new Set(digests)];
}

const apkName = path.basename(apk);
const downloadUrl = `https://github.com/${repo}/releases/download/${tag}/${apkName}`;
const url = `https://github.com/${repo}/releases/tag/${tag}`;

let changelog = '';
if (changelogFile && fs.existsSync(changelogFile)) {
  changelog = fs.readFileSync(changelogFile, 'utf8').trim();
}

const entry = {
  version,
  build,
  url,
  download_url: downloadUrl,
  ...(changelog ? { changelog } : {}),
  signatures: signerSha1s(apk),
};

let feed = {};
if (fs.existsSync(out)) {
  try {
    feed = JSON.parse(fs.readFileSync(out, 'utf8'));
  } catch (e) {
    console.error(`existing feed is not valid JSON: ${e.message}`);
    process.exit(1);
  }
}
feed.android = feed.android || {};
const existing = Array.isArray(feed.android[channel])
  ? feed.android[channel]
  : feed.android[channel]
    ? [feed.android[channel]]
    : [];
const merged = existing.filter((e) => e && e.build !== build);
merged.push(entry);
merged.sort((a, b) => b.build - a.build);
feed.android[channel] = merged;

fs.writeFileSync(out, `${JSON.stringify(feed, null, 2)}\n`);
console.log(
  `feed updated: ${out} channel=${channel} build=${build} version=${version} ` +
    `signatures=${entry.signatures.join(',')}`,
);
