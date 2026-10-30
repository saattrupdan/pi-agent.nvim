import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const path = process.env.PI_AGENT_STATUS_FILE;
  if (!path) return;

  let working = false;
  let awaitingInput = false;

  function publish() {
    try {
      writeFileSync(path, awaitingInput ? "need_input" : working ? "working" : "idle");
    } catch {
      // An unavailable status file must not interrupt Pi.
    }
  }

  publish();
  pi.on("session_start", () => {
    working = false;
    awaitingInput = false;
    publish();
  });
  pi.on("agent_start", () => {
    working = true;
    publish();
  });
  pi.on("agent_end", () => {
    working = false;
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
