import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const MINIMUM_CODEX_VERSION = [0, 144, 0] as const;

function parseVersion(value: string) {
  const match = value.match(/(\d+)\.(\d+)\.(\d+)/);
  return match ? match.slice(1).map(Number) : null;
}

function isCompatibleVersion(version: number[] | null) {
  if (!version) return false;
  for (let index = 0; index < MINIMUM_CODEX_VERSION.length; index += 1) {
    if (version[index] > MINIMUM_CODEX_VERSION[index]) return true;
    if (version[index] < MINIMUM_CODEX_VERSION[index]) return false;
  }
  return true;
}

export async function inspectCodex() {
  if (Number(process.versions.node.split(".")[0]) < 22) {
    return {
      available: false as const,
      reason: "The Codex provider requires Node.js 22 or newer",
    };
  }

  try {
    const { stdout, stderr } = await execFileAsync("codex", ["--version"], {
      timeout: 5_000,
    });
    const versionOutput = `${stdout} ${stderr}`.trim();
    if (!isCompatibleVersion(parseVersion(versionOutput))) {
      return {
        available: false as const,
        reason: `Codex ${versionOutput || "version unknown"} is older than 0.144.0`,
      };
    }
    return { available: true as const, versionOutput };
  } catch (error) {
    return {
      available: false as const,
      reason: error instanceof Error ? error.message : "Codex is unavailable",
    };
  }
}

export async function getProviderRuntime() {
  const codex = await inspectCodex();
  return {
    provider: (codex.available ? "codex-cli" : "openrouter") as
      | "codex-cli"
      | "openrouter",
    codex,
    openRouterConfigured: Boolean(process.env.OPENROUTER_API_KEY),
    googlePlacesConfigured: Boolean(process.env.GOOGLE_MAPS_PLACES_API_KEY),
  };
}
