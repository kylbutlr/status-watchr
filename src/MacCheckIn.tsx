import { useEffect, useState } from "react";
import { relativeTime } from "./domain";

export function MacCheckIn({ receivedAt }: { receivedAt?: string }) {
  const [, setClock] = useState(0);
  useEffect(() => {
    const refresh = () => setClock((value) => value + 1);
    const timer = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);

  const valid = receivedAt && Number.isFinite(Date.parse(receivedAt));
  return <span className="mac-check-in">Mac last checked in: {valid
    ? <time dateTime={receivedAt} title={new Date(receivedAt).toLocaleString()}>{relativeTime(receivedAt).toLowerCase()}</time>
    : "Unavailable"}</span>;
}
