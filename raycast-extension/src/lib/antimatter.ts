import { open } from "@raycast/api";

const SCHEME = "antimatter";

export function antimatterURL(path: string, query?: Record<string, string>): URL {
  const url = new URL(`${SCHEME}://${path}`);
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      url.searchParams.set(k, v);
    }
  }
  return url;
}

export async function openAntimatter(path?: string, query?: Record<string, string>): Promise<void> {
  await open(antimatterURL(path ?? "", query).toString());
}

export const DOT_COMMANDS = [
  { label: "5 min timer", command: ".timer 5" },
  { label: "10 min timer", command: ".timer 10" },
  { label: "15 min timer", command: ".timer 15" },
  { label: "25 min timer", command: ".timer 25" },
  { label: "1 min timer", command: ".timer 1" },
  { label: "Start stopwatch", command: ".stopwatch" },
  { label: "Cancel timers", command: ".timer cancel" },
  { label: "Cancel stopwatches", command: ".stopwatch cancel" },
  { label: "Remind in 5 min", command: ".remind in 5 mins" },
  { label: "Remind in 10 min", command: ".remind in 10 mins" },
  { label: "Cancel reminders", command: ".reminder cancel" },
  { label: "Sum numbers", command: ".sum" },
  { label: "Average numbers", command: ".avg" },
  { label: "Count numbers", command: ".count" },
  { label: "Open settings", command: ".settings" },
  { label: "Show help", command: ".help" },
  { label: "Export to Apple Notes", command: ".export notes" },
  { label: "Paste stream", command: ".paste" },
  { label: "Pomodoro 25/5/4", command: ".pomodoro 25/5/4" },
] as const;
