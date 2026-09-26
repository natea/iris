// The Hermes function declarations the Live model sees. They live here, not in
// main.mjs, because two clients now use them: the desktop session and the
// mobile session config baked into a paired phone's ephemeral token
// (electron/mobileSession.mjs). Copies would drift, and a drifted schema means
// the two Irises behave differently for the same spoken request.
export const HERMES_FUNCTION_DECLARATIONS = Object.freeze([
  {
    name: "check_hermes_status",
    description:
      "Check whether Hermes is reachable and ready. Call immediately when the user asks about Hermes connectivity; this is read-only and needs no confirmation.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "propose_hermes_task",
    description:
      "STEP 1 of dispatching work to Hermes. Use ONLY when the user explicitly asks Iris to use, ask, send, or delegate work to Hermes. This stages a complete brief but does not send it. Never use it for ordinary conversation, Google Search, memory/brain retrieval, status checks, or Iris UI controls. After this call, briefly read back the goal, ask whether to send it, and end the turn.",
    parameters: {
      type: "object",
      properties: {
        goal: {
          type: "string",
          description:
            "What the user wants Hermes to accomplish. Preserve concrete details the user supplied.",
        },
        context: {
          type: "string",
          description:
            "Only context explicitly supplied by the user or established in this conversation, including user-supplied file paths or named tools.",
        },
        constraints: {
          type: "array",
          items: { type: "string" },
          description: "User-supplied limits, deadlines, budgets, exclusions, or safety requirements.",
        },
        acceptance_criteria: {
          type: "array",
          items: { type: "string" },
          description: "Observable conditions that make the work complete.",
        },
        output_format: {
          type: "string",
          description: "The requested result format, if the user specified one.",
        },
        urgency: {
          type: "string",
          enum: ["low", "normal", "high"],
          description: "Dispatch priority.",
        },
      },
      required: ["goal"],
    },
  },
  {
    name: "submit_hermes_task",
    description:
      "Send the exact staged Hermes proposal. Call only when the meaning of the user's latest response clearly authorizes sending after the readback; confirmation has no required wording. If intent is ambiguous, ask naturally instead of calling. Never restage an unchanged confirmed proposal.",
    parameters: {
      type: "object",
      properties: {
        proposal_id: {
          type: "string",
          description:
            "The proposal_id returned by propose_hermes_task. It cannot be replaced or edited.",
        },
      },
      required: ["proposal_id"],
    },
  },
  {
    name: "discard_hermes_proposal",
    description:
      "Discard an unsent staged Hermes proposal when the user's response means they decline or cancel it. Interpret intent conversationally; no particular rejection phrase is required. This does not stop a task that was already submitted.",
    parameters: {
      type: "object",
      properties: {
        proposal_id: {
          type: "string",
          description: "The proposal_id returned by propose_hermes_task.",
        },
      },
      required: ["proposal_id"],
    },
  },
  {
    name: "get_hermes_task_status",
    description:
      "Read the current status or final output of a Hermes run. Call immediately when asked how a run is going; no confirmation is needed. Report only returned status/output and never invent progress.",
    parameters: {
      type: "object",
      properties: { run_id: { type: "string" } },
      required: ["run_id"],
    },
  },
  {
    name: "stop_hermes_task",
    description:
      "Stop an active Hermes run when the user clearly asks to stop or cancel it. Execute directly without an additional confirmation.",
    parameters: {
      type: "object",
      properties: { run_id: { type: "string" } },
      required: ["run_id"],
    },
  },
  {
    name: "approve_hermes_action",
    description:
      "Resolve a real pending Hermes approval only after Iris has described the command and the user explicitly chose once, session, always, or deny in their own turn. The app verifies that the spoken answer matches the choice.",
    parameters: {
      type: "object",
      properties: {
        run_id: { type: "string" },
        choice: { type: "string", description: "once, session, always, or deny" },
      },
      required: ["run_id", "choice"],
    },
  },
  {
    name: "respond_hermes_interaction",
    description:
      "Resume a Hermes clarification or full-protocol approval after the user answered in their own turn. Pass the exact run_id, interaction_id, and interaction_type from SYSTEM_EVENT_HERMES_INTERACTION_REQUIRED. For approval also pass choice. Do not use for sudo/password/secret prompts: those are secure UI-only.",
    parameters: {
      type: "object",
      properties: {
        run_id: { type: "string" },
        interaction_id: { type: "string" },
        interaction_type: {
          type: "string",
          enum: ["clarify", "approval"],
        },
        choice: {
          type: "string",
          enum: ["once", "session", "always", "deny"],
          description: "Required only for approval.",
        },
      },
      required: ["run_id", "interaction_id", "interaction_type"],
    },
  },
]);
