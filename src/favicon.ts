import { faviconHref, type FaviconStatus } from "./domain";

export function replaceFavicon(status: FaviconStatus) {
  const current = document.querySelector<HTMLLinkElement>("#status-watchr-favicon");
  if (!current) return;

  const href = faviconHref(status);
  if (current.getAttribute("href") === href) return;

  const replacement = current.cloneNode(true) as HTMLLinkElement;
  replacement.setAttribute("href", href);
  current.replaceWith(replacement);
}
