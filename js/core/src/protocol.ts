export const PROTOCOL = 1;

export const UPGRADE_NEEDED = "This device's Babel Sync is too old for the server. Update it to sync again.";

export function refusal(reason: string | undefined): string {
  return reason === "upgrade" ? UPGRADE_NEEDED : (reason ?? "error");
}
