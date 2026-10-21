import { automaticWorkAllowed } from "./lib/work-switch.js";
import { neon } from "@neondatabase/serverless";
import { retryNotificationWakes } from "./lib/notification-wakes.js";

export default async function handler() {
  if (!process.env.DATABASE_URL || !await automaticWorkAllowed()) return;
  try {
    await retryNotificationWakes(() => neon(process.env.DATABASE_URL!));
  } catch {
    console.error("Status Watchr notification retry or retention unavailable");
    throw new Error("Notification maintenance unavailable");
  }
}

export const config = { schedule: "* * * * *" };
