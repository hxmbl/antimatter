import { open } from "@raycast/api";

const SCHEME = "antimatter";

/** Ports the app binds in order; must match LocalBridge in the app. */
export const BRIDGE_PORTS = [41367, 41368, 41369];

const READINESS_TIMEOUT_MS = 6_000;
const PING_INTERVAL_MS = 300;

interface BridgeResponse {
  ok: boolean;
  message: string;
}

export function antimatterURL(
  path: string,
  query?: Record<string, string>,
): URL {
  const url = new URL(`${SCHEME}://${path}`);
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      url.searchParams.set(k, v);
    }
  }
  return url;
}

export async function openAntimatter(
  path?: string,
  query?: Record<string, string>,
): Promise<void> {
  await open(antimatterURL(path ?? "", query).toString());
}

export async function bridgeFetch(
  path: string,
): Promise<BridgeResponse | null> {
  for (const port of BRIDGE_PORTS) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 1_500);
      try {
        const response = await fetch(`http://127.0.0.1:${port}${path}`, {
          signal: controller.signal,
        });
        if (!response.ok) continue;
        const body = (await response.json()) as BridgeResponse;
        return body;
      } finally {
        clearTimeout(timer);
      }
    } catch {
      // connection refused / aborted — try the next port
    }
  }
  return null;
}

export async function runCommand(line: string): Promise<BridgeResponse> {
  return runAction(`/command?line=${encodeURIComponent(line)}`);
}

export async function createNote(text: string): Promise<BridgeResponse> {
  return runAction(`/note?text=${encodeURIComponent(text)}`);
}

/**
 * Fast happy path: fire the action alone. Only if nothing answers — the app
 * isn't up — do we launch it and poll, so an already-running app costs
 * exactly one round-trip.
 */
async function runAction(path: string): Promise<BridgeResponse> {
  const attempted = await bridgeFetch(path);
  if (attempted) return attempted;

  await openAntimatter();
  const deadline = Date.now() + READINESS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const response = await bridgeFetch(path);
    if (response) return response;
    await new Promise((resolve) => setTimeout(resolve, PING_INTERVAL_MS));
  }
  return {
    ok: false,
    message: "Antimatter isn't responding — open the app and try again",
  };
}
