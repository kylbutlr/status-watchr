// Push only. Never cache authenticated pages, API responses, titles, or timelines.
self.addEventListener("push", (event) => {
  let payload;
  try { payload = event.data?.json(); } catch { return; }
  if (!payload || typeof payload.tag !== "string") return;
  const allowed = new Set([
    "A watched conversation needs your attention.",
    "A watched run failed. Open your private dashboard.",
    "A watched run finished. Open your private dashboard.",
    "Test notification. Your private phone alert path is connected.",
  ]);
  if (!allowed.has(payload.body)) return;
  // The server keeps generic body copy so older installed workers can still display the push.
  const conversationTitle = typeof payload.conversationTitle === "string"
    ? payload.conversationTitle.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim()
    : "";
  const showTitle = Boolean(conversationTitle) && Array.from(conversationTitle).length <= 120 && conversationTitle !== "Untitled task";
  const shortBody = {
    "A watched run finished. Open your private dashboard.": "Run finished.",
    "A watched run failed. Open your private dashboard.": "Run failed.",
    "A watched conversation needs your attention.": "Needs your attention.",
  };
  const replyPreview = payload.body === "A watched run finished. Open your private dashboard." && typeof payload.replyPreview === "string"
    ? payload.replyPreview.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim()
    : "";
  const showReply = Boolean(replyPreview) && replyPreview.length <= 180;
  const body = showReply ? `Run finished: ${replyPreview}` : showTitle ? shortBody[payload.body] ?? payload.body : payload.body;
  event.waitUntil(self.registration.showNotification(showTitle ? conversationTitle : "Status Watchr", {
    body, tag: payload.tag, icon: "/icons/status-watchr-192.png", data: { url: "/" },
  }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  // Never navigate to an arbitrary URL supplied in a push payload.
  event.waitUntil(clients.openWindow(new URL("/", self.location.origin).href));
});
