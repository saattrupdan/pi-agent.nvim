import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const path = process.env.PI_AGENT_STATUS_FILE;
  if (!path) return;

  let working = false;
  let awaitingInput = false;
  let completedRuns = 0;
  let finished = false;

  function publish() {
    try {
      const status = awaitingInput
        ? "need_input"
        : working
          ? "working"
          : finished
            ? `finished:${completedRuns}`
            : "idle";
      writeFileSync(path, status);
    } catch {
      // An unavailable status file must not interrupt Pi.
    }
  }

  publish();
  pi.on("session_start", () => {
    working = false;
    awaitingInput = false;
    finished = false;
    publish();
  });
  pi.on("before_agent_start", () => {
    working = true;
    finished = false;
    publish();
  });
  pi.on("agent_start", () => {
    working = true;
    finished = false;
    publish();
  });
  pi.on("agent_settled", () => {
    working = false;
    finished = true;
    completedRuns += 1;
    publish();
  });
  pi.on("ui_prompt_start", () => {
    awaitingInput = true;
    publish();
  });
  pi.on("ui_prompt_end", () => {
    awaitingInput = false;
    publish();
  });
}
