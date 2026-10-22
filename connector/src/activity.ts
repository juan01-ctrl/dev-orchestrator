export type ActivityStage =
  | "agent_started"
  | "working"
  | "editing"
  | "validating"
  | "checks_passed";

const validationCommand = /\b(test|tests|spec|lint|format|typecheck|type-check|check|build|compile)\b/i;

export function activityForNotification(message: any): ActivityStage | undefined {
  if (!message || typeof message !== "object" || !message.params) return undefined;

  if (message.method === "turn/started") return "agent_started";

  const item = message.params.item;
  if (message.method === "item/started") {
    if (item?.type === "fileChange") return "editing";
    if (item?.type === "commandExecution") {
      return validationCommand.test(String(item.command ?? "")) ? "validating" : "working";
    }
  }

  if (
    message.method === "item/completed" &&
    item?.type === "commandExecution" &&
    validationCommand.test(String(item.command ?? "")) &&
    item.exitCode === 0
  ) {
    return "checks_passed";
  }

  return undefined;
}
