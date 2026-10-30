import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const path = process.env.PI_AGENT_STATUS_FILE;
  if (!path) return;

  function setStatus(status: "idle" | "working") {
    try {
      writeFileSync(path, status);
    } catch {
      // Status is best-effort; an unavailable status file must not interrupt Pi.
    }
  }

  setStatus("idle");
  pi.on("session_start", () => setStatus("idle"));
  pi.on("agent_start", () => setStatus("working"));
  pi.on("agent_end", () => setStatus("idle"));
}
