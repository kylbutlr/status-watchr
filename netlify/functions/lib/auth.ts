import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export const sessionCookieName = "status_watchr_session";
const sessionLifetimeSeconds = 60 * 60 * 24 * 30;

function env(name: string) {
  return process.env[name]?.trim() ?? "";
}

function safeEqual(left: string, right: string) {
  const leftDigest = createHash("sha256").update(left).digest();
  const rightDigest = createHash("sha256").update(right).digest();
  return timingSafeEqual(leftDigest, rightDigest);
}

function sign(value: string) {
  return createHmac("sha256", env("WATCHR_SESSION_SECRET")).update(value).digest("base64url");
}

export function isPasswordConfigured() {
  return Boolean(env("WATCHR_ACCESS_PASSWORD") && env("WATCHR_SESSION_SECRET"));
}

export function verifyAccessPassword(password: string) {
  const expected = env("WATCHR_ACCESS_PASSWORD");
  return Boolean(expected) && safeEqual(password, expected);
}

export function createSessionValue() {
  const expiresAt = Date.now() + sessionLifetimeSeconds * 1000;
  const payload = `${expiresAt}.${randomBytes(18).toString("base64url")}`;
  return `${payload}.${sign(payload)}`;
}

export function isValidSessionValue(value: string | null) {
  if (!value || !env("WATCHR_SESSION_SECRET")) return false;
  const parts = value.split(".");
  if (parts.length !== 3) return false;
  const [expiresAt, nonce, signature] = parts;
  const payload = `${expiresAt}.${nonce}`;
  return Number(expiresAt) > Date.now() && safeEqual(signature, sign(payload));
}

export function sessionValueFromRequest(request: Request) {
  const cookieHeader = request.headers.get("cookie") ?? "";
  const cookie = cookieHeader.split(";").map((part) => part.trim()).find((part) => part.startsWith(`${sessionCookieName}=`));
  try { return cookie ? decodeURIComponent(cookie.slice(sessionCookieName.length + 1)) : null; }
  catch { return null; }
}

export function hasValidSession(request: Request) {
  return isValidSessionValue(sessionValueFromRequest(request));
}

export function sessionCookie(value: string, secure = true) {
  return `${sessionCookieName}=${encodeURIComponent(value)}; Path=/; Max-Age=${sessionLifetimeSeconds}; HttpOnly; SameSite=Strict${secure ? "; Secure" : ""}`;
}

export function clearedSessionCookie(secure = true) {
  return `${sessionCookieName}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict${secure ? "; Secure" : ""}`;
}

export function hasValidIngestToken(request: Request) {
  const expected = env("WATCHR_INGEST_TOKEN");
  const authorization = request.headers.get("authorization") ?? "";
  return Boolean(expected) && safeEqual(authorization, `Bearer ${expected}`);
}
