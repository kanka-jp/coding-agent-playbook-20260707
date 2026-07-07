#!/usr/bin/env bun
/**
 * detect-generated.ts - GitHub PR の自動生成ファイルを検出する
 *
 * 変更ファイルを名前規則 / .gitattributes / 先頭マーカーで判定し、生成物の一覧を
 * JSON で出力する。マークは行わない (呼び出し側が markFileAsViewed を発行する)。
 *
 * Usage:
 *   detect-generated.ts <pr-number> [--repo owner/repo]
 *   detect-generated.ts <pr-url>
 *
 * Exit codes:
 *   0: 成功 (generated が空でも 0)
 *   1: 引数不足 / 形式不正
 *   2: gh 認証エラー
 *   3: PR / repo 未検出
 *   6: その他
 */

import {
  classifyByName,
  classifyByContent,
  parseGitattributes,
  gitattributesGenerated,
} from "../../_shared/generated-detect.ts";

// ============================================================
// PR ref parsing (テスト対象)
// ============================================================

export type PrRef = { owner: string | null; repo: string | null; number: number };

export function parsePrRef(arg: string): PrRef | null {
  const urlMatch = arg.match(
    /^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)(?:[/?#].*)?$/,
  );
  if (urlMatch) {
    return { owner: urlMatch[1], repo: urlMatch[2], number: Number(urlMatch[3]) };
  }
  if (/^\d+$/.test(arg)) {
    return { owner: null, repo: null, number: Number(arg) };
  }
  return null;
}

// contents endpoint に渡すパスを segment 単位で encode する。`#` / `?` / 空白等を
// 含むパスでも query string や fragment と誤解釈されず endpoint が壊れない (`/` は保持)
export function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

export type ParsedArgs = { repoFlag: string | null; positional: string[]; error: string | null };

// `--repo` に値が無い (末尾 / 次が別フラグ) 場合は error にする。null で黙って repo
// 自動検出にフォールバックすると意図しない repo の同番号 PR を対象にしうるため
export function parseArgs(argv: string[]): ParsedArgs {
  let repoFlag: string | null = null;
  const positional: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--repo") {
      const v = argv[++i];
      if (v === undefined || v.startsWith("-")) {
        return { repoFlag: null, positional, error: "--repo には owner/repo を指定してください。" };
      }
      repoFlag = v;
    } else {
      positional.push(argv[i]);
    }
  }
  return { repoFlag, positional, error: null };
}

// ============================================================
// gh I/O (副作用)
// ============================================================

async function gh(
  args: string[],
): Promise<{ ok: boolean; stdout: string; stderr: string; code: number }> {
  const proc = Bun.spawn(["gh", ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  return { ok: code === 0, stdout, stderr, code };
}

function isAuthError(stderr: string): boolean {
  return /gh auth login|HTTP 401|Bad credentials|authentication/i.test(stderr);
}

async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (t: T, i: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let idx = 0;
  async function worker() {
    while (true) {
      const i = idx++;
      if (i >= items.length) break;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker),
  );
  return results;
}

function fail(code: number, message: string): never {
  console.error(`detect-generated: ${message}`);
  process.exit(code);
}

// ============================================================
// Main
// ============================================================

async function main() {
  const { repoFlag, positional, error } = parseArgs(process.argv.slice(2));
  if (error) fail(1, error);

  if (positional.length === 0) {
    fail(1, "PR 番号または PR URL を指定してください。");
  }

  const ref = parsePrRef(positional[0]);
  if (!ref) {
    fail(1, `PR 番号 (例: 768) または PR URL (例: https://github.com/owner/repo/pull/768) を指定してください: ${positional[0]}`);
  }

  let owner = ref.owner;
  let repo = ref.repo;
  if (!owner || !repo) {
    if (repoFlag) {
      const m = repoFlag.match(/^([^/]+)\/([^/]+)$/);
      if (!m) fail(1, `--repo は owner/repo 形式で指定してください: ${repoFlag}`);
      owner = m[1];
      repo = m[2];
    } else {
      const r = await gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
      if (!r.ok) {
        if (isAuthError(r.stderr)) fail(2, `gh 認証エラー: ${r.stderr.trim()}`);
        fail(3, `カレントディレクトリの repo を特定できません。--repo owner/repo を指定してください。\n${r.stderr.trim()}`);
      }
      const m = r.stdout.trim().match(/^([^/]+)\/([^/]+)$/);
      if (!m) fail(6, `nameWithOwner の解析に失敗: ${r.stdout.trim()}`);
      owner = m[1];
      repo = m[2];
    }
  }

  const slug = `${owner}/${repo}`;

  const meta = await gh([
    "pr", "view", String(ref.number), "--repo", slug, "--json", "id,headRefOid",
  ]);
  if (!meta.ok) {
    if (isAuthError(meta.stderr)) fail(2, `gh 認証エラー: ${meta.stderr.trim()}`);
    fail(3, `PR #${ref.number} (${slug}) を取得できません。\n${meta.stderr.trim()}`);
  }
  const { id: prNodeId, headRefOid: headSha } = JSON.parse(meta.stdout);

  const filesRes = await gh([
    "api", `repos/${slug}/pulls/${ref.number}/files`, "--paginate",
    "--jq", ".[] | [.filename, .status] | @tsv",
  ]);
  if (!filesRes.ok) {
    if (isAuthError(filesRes.stderr)) fail(2, `gh 認証エラー: ${filesRes.stderr.trim()}`);
    fail(6, `PR files の取得に失敗: ${filesRes.stderr.trim()}`);
  }
  const files = filesRes.stdout
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => {
      const [path, status] = l.split("\t");
      return { path, status };
    });

  const gaRes = await gh([
    "api", `repos/${slug}/contents/.gitattributes?ref=${headSha}`,
    "-H", "Accept: application/vnd.github.raw",
  ]);
  const gaEntries = gaRes.ok ? parseGitattributes(gaRes.stdout) : [];

  // gitattributes (最優先) → 名前 の順で判定し、残りだけ内容 fetch する
  type Detected = { path: string; reason: string };
  const generated: Detected[] = [];
  const review: string[] = [];
  const needContent: { path: string; status: string }[] = [];

  for (const f of files) {
    // .gitattributes の明示指定は GitHub Linguist の正準シグナルのため name/content 判定より優先する
    const gaResult = gaEntries.length > 0 ? gitattributesGenerated(f.path, gaEntries) : null;
    if (gaResult === true) {
      generated.push({ path: f.path, reason: "gitattributes:linguist-generated" });
      continue;
    }
    if (gaResult === false) {
      review.push(f.path);
      continue;
    }
    const nameReason = classifyByName(f.path);
    if (nameReason) {
      generated.push({ path: f.path, reason: nameReason });
      continue;
    }
    // removed は head に存在せず内容 fetch 不能。名前で拾えなければ review に回す
    if (f.status === "removed") {
      review.push(f.path);
      continue;
    }
    needContent.push(f);
  }

  // 内容 fetch + マーカー判定 (並列)。404 (submodule 等) / binary / 取得失敗は
  // 安全側で review に残す
  const contentResults = await mapLimit(needContent, 8, async (f) => {
    const r = await gh([
      "api", `repos/${slug}/contents/${encodePath(f.path)}?ref=${headSha}`,
      "-H", "Accept: application/vnd.github.raw",
    ]);
    return { path: f.path, reason: r.ok ? classifyByContent(r.stdout) : null };
  });

  for (const res of contentResults) {
    if (res.reason) generated.push({ path: res.path, reason: res.reason });
    else review.push(res.path);
  }

  // 元の PR 順を保つ
  const order = new Map(files.map((f, i) => [f.path, i]));
  generated.sort((a, b) => (order.get(a.path) ?? 0) - (order.get(b.path) ?? 0));
  review.sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0));

  const out = {
    repo: slug,
    pr_number: ref.number,
    pr_node_id: prNodeId,
    head_sha: headSha,
    total_changed: files.length,
    generated,
    review,
  };
  console.log(JSON.stringify(out, null, 2));
}

if (import.meta.main) {
  main().catch((e) => {
    fail(6, `予期しないエラー: ${e?.message ?? e}`);
  });
}
