import { open } from "@raycast/api";

const SCHEME = "antimatter";

/** Ports the app binds in order; must match LocalBridge in the app. */
export const BRIDGE_PORTS = [41367, 41368, 41369];

const READINESS_TIMEOUT_MS = 6_000;
const PING_INTERVAL_MS = 300;
const REQUEST_TIMEOUT_MS = 1_500;

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

/** One GET with a hard deadline; `null` for "nothing usable answered". */
async function fetchBridge(
  port: number,
  path: string,
): Promise<BridgeResponse | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      signal: controller.signal,
    });
    if (!response.ok) return null;
    return (await response.json()) as BridgeResponse;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Identity check for a port.
 *
 * `/ping` is the app's non-mutating endpoint and answers
 * `{"ok":true,"message":""}`. Taking the first responder on any port blindly
 * meant an unrelated process squatting on 41367 received the command, so every
 * candidate port is now confirmed to actually be Antimatter first.
 */
export async function bridgePing(port: number): Promise<boolean> {
  const body = await fetchBridge(port, "/ping");
  return body?.ok === true && body.message === "";
}

/**
 * Sends a request to a port already proven to be Antimatter. Only used once
 * `activeBridgePort()` has vouched for the port.
 */
export async function bridgeFetch(
  port: number,
  path: string,
): Promise<BridgeResponse | null> {
  return fetchBridge(port, path);
}

/**
 * The single port currently answering as Antimatter, or null.
 *
 * The answer is cached: probing costs one round-trip and repeating it on every
 * action would slow the common path down for no benefit. A negative result is
 * not cached, so a cold launch is still detected on the next call.
 */
let verifiedPort: number | null = null;

async function activeBridgePort(): Promise<number | null> {
  if (verifiedPort !== null) return verifiedPort;
  for (const port of BRIDGE_PORTS) {
    if (await bridgePing(port)) {
      verifiedPort = port;
      return port;
    }
  }
  return null;
}

export function resetBridgeCache(): void {
  verifiedPort = null;
}

export async function runCommand(line: string): Promise<BridgeResponse> {
  return runAction(`/command?line=${encodeURIComponent(line)}`);
}

export async function createNote(text: string): Promise<BridgeResponse> {
  return runAction(`/note?text=${encodeURIComponent(text)}`);
}

/**
 * Liveness is decided by `/ping`, never by the action itself.
 *
 * `runAction` used to fire the action as its own probe: anything slower than
 * 1.5 s looked identical to "the app isn't running", so the action ran, timed
 * out, a second app instance was launched, and the action was replayed. Only
 * `TimerCenter.start` had a duplicate guard — `/note`, `/append`, `.new`,
 * `.stopwatch` and `.pomodoro` had none, so they really did run twice.
 *
 * `/ping` mutates nothing, so an already-running app costs one cheap
 * round-trip and the action is sent exactly once.
 */
async function runAction(path: string): Promise<BridgeResponse> {
  let port = await activeBridgePort();

  if (port === null) {
    // Nothing is listening: launch, then poll `/ping` only.
    await openAntimatter();
    const deadline = Date.now() + READINESS_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, PING_INTERVAL_MS));
      port = await activeBridgePort();
      if (port !== null) break;
    }
  }

  if (port === null) {
    return {
      ok: false,
      message: "Antimatter isn't responding — open the app and try again",
    };
  }

  const response = await bridgeFetch(port, path);
  if (response) return response;

  // The app answered `/ping` but not the action: it most likely quit or was
  // replaced in between. The action may well have run, so it is NOT replayed.
  verifiedPort = null;
  return {
    ok: false,
    message: "Antimatter didn't answer — open the app and try again",
  };
}
