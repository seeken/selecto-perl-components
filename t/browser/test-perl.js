import {execFileSync} from "node:child_process";

// The Perl that runs browser fixture servers: the one CI pins
// (SELECTO_TEST_PERL), else this checkout's mise Perl, else perl on PATH.
export function testPerl(root) {
  if (process.env.SELECTO_TEST_PERL) return process.env.SELECTO_TEST_PERL;
  try {
    return execFileSync("mise", ["which", "perl"], {cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]}).trim();
  } catch (_) {
    return "perl";
  }
}
