import { expect, test, describe } from "bun:test";
import { parseGitattributes, gitattributesGenerated } from "./generated-detect.ts";

describe("parseGitattributes + gitattributesGenerated", () => {
  test("simple linguist-generated rule", () => {
    const entries = parseGitattributes("*.pb.go linguist-generated=true\n");
    expect(gitattributesGenerated("api/x.pb.go", entries)).toBe(true);
    // 該当ルールが無いファイルは null (「明示的に false」ではなく「該当ルール無し」)
    expect(gitattributesGenerated("api/x.go", entries)).toBeNull();
  });

  test("bare linguist-generated (no =true)", () => {
    const entries = parseGitattributes("schema.graphql linguist-generated\n");
    expect(gitattributesGenerated("schema.graphql", entries)).toBe(true);
  });

  test("later rule overrides earlier (unset)", () => {
    const entries = parseGitattributes(
      "gen/** linguist-generated\ngen/keep.ts -linguist-generated\n",
    );
    expect(gitattributesGenerated("gen/a.ts", entries)).toBe(true);
    expect(gitattributesGenerated("gen/keep.ts", entries)).toBe(false);
  });

  test("comments and blank lines ignored", () => {
    const entries = parseGitattributes("# comment\n\n*.lock linguist-generated\n");
    expect(entries.length).toBe(1);
  });

  // -linguist-generated による明示的な opt-out (false) と、該当ルールが無いケース (null) を
  // 区別できないと、呼び出し側は opt-out を名前パターン判定より優先できない
  test("explicit opt-out is distinguishable from no-match", () => {
    const entries = parseGitattributes("package-lock.json -linguist-generated\n");
    expect(gitattributesGenerated("package-lock.json", entries)).toBe(false);
    expect(gitattributesGenerated("unrelated.ts", entries)).toBeNull();
  });

  // `!attr` は前の行の設定を打ち消して unspecified に戻す Git 標準構文
  test("!linguist-generated resets a prior rule to unspecified", () => {
    const entries = parseGitattributes(
      "package-lock.json -linguist-generated\npackage-lock.json !linguist-generated\n",
    );
    expect(gitattributesGenerated("package-lock.json", entries)).toBeNull();
  });
});
