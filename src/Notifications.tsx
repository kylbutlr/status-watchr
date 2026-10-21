import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { notificationDuration } from './notification-duration';
import { mapLiveSessions, type AgentSession } from './domain';

type Settings = { configured: boolean; publicKey: string | null; allAlways?: boolean; allUntil: string | null; serverNow: string; watches: { thread_id: string; enabled: boolean; session?: unknown }[]; devices: { id: string; created_at: string }[] };
export type WatchedConversation = { threadId: string; session?: AgentSession };

async function api(path = "", method = "GET", body?: unknown) {
  const response = await fetch(`/api/notifications${path}`, {
    method, headers: method === "GET" ? {} : { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error ?? "Notification settings unavailable. Try again.");
  return result;
}

const alwaysAllowed = () => true;

function useNotificationSettings(demo: boolean, automaticAllowed: () => boolean, workChange: string) {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [deviceId, setDeviceId] = useState(() => localStorage.getItem("statusWatchr.pushDevice") ?? "");
  const [clock, setClock] = useState(Date.now());
  const offset = useRef(0);
  const pending = useRef(false);
  const revision = useRef(0);
  const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const currentDevice = settings?.devices.some((device) => device.id === deviceId) ?? false;
  const allActive = Boolean(settings?.allAlways || (settings?.allUntil && Date.parse(settings.allUntil) > clock + offset.current));

  function receive(result: Settings) {
    offset.current = result.serverNow ? Date.parse(result.serverNow) - Date.now() : 0;
    setClock(Date.now()); setSettings(result);
  }

  useEffect(() => {
    if (demo) return;
    let cancelled = false;
    let inFlight = false;
    const refresh = () => {
      if (document.visibilityState === 'hidden') return;
      // Expiry is local UI state: returning from suspension must not wait for the network.
      setClock(Date.now());
      if (pending.current || inFlight || !automaticAllowed() || !navigator.onLine) return;
      inFlight = true;
      const version = ++revision.current;
      api().then((result) => { if (!cancelled && version === revision.current) receive(result); }).catch(() => { if (!cancelled && version === revision.current) setMessage("Notification settings unavailable. Open device settings to retry."); }).finally(() => { inFlight = false; });
    };
    refresh();
    const interval = window.setInterval(refresh, 600_000);
    window.addEventListener('focus', refresh);
    window.addEventListener('pageshow', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => { cancelled = true; window.clearInterval(interval); window.removeEventListener('focus', refresh); window.removeEventListener('pageshow', refresh); document.removeEventListener('visibilitychange', refresh); };
  }, [demo, automaticAllowed, workChange]);

  useEffect(() => {
    if (!settings?.allUntil) return;
    const remaining = Date.parse(settings.allUntil) - Date.now() - offset.current;
    if (remaining <= 0) return;
    const timer = window.setTimeout(() => setClock(Date.now()), remaining + 1);
    return () => window.clearTimeout(timer);
  }, [settings]);

  async function action(work: () => Promise<void>) {
    if (pending.current) return;
    pending.current = true;
    revision.current += 1;
    setBusy(true); setMessage("");
    try { await work(); receive(await api()); }
    catch (error) { setMessage(error instanceof Error ? error.message : "Could not save. Try again."); }
    finally { pending.current = false; setBusy(false); }
  }

  async function enable() {
    // Permission must be requested directly from a tap, before any network await.
    const permission = await Notification.requestPermission();
    if (permission !== "granted") throw new Error("Notifications are not allowed. Enable them for Status Watchr in your device settings.");
    await navigator.serviceWorker.register("/sw.js");
    const registration = await navigator.serviceWorker.ready;
    const key = Uint8Array.from(atob(settings!.publicKey!.replace(/-/g, "+").replace(/_/g, "/")), (character) => character.charCodeAt(0));
    const subscription = await registration.pushManager.getSubscription() ?? await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
    const result = await api("/subscribe", "POST", { subscription: subscription.toJSON() });
    setDeviceId(result.id); localStorage.setItem("statusWatchr.pushDevice", result.id);
    setMessage("Device enabled. Send a test, then watch the conversations you care about.");
  }

  return { automaticPaused: !demo && !automaticAllowed(), settings, busy, message, setMessage, deviceId, setDeviceId, supported, currentDevice, allActive, action, enable };
}

const NotificationContext = createContext<ReturnType<typeof useNotificationSettings> | null>(null);
export function NotificationProvider({ demo, children, automaticAllowed = alwaysAllowed, workChange = "" }: { demo: boolean; children: ReactNode; automaticAllowed?: () => boolean; workChange?: string }) {
  return <NotificationContext.Provider value={useNotificationSettings(demo, automaticAllowed, workChange)}>{children}</NotificationContext.Provider>;
}
function useNotifications() {
  const value = useContext(NotificationContext);
  if (!value) throw new Error('NotificationProvider required');
  return value;
}

export function Notifications({ threadId, demo }: { threadId?: string; demo: boolean }) {
  const { settings, busy, message, setMessage, currentDevice, allActive, action } = useNotifications();
  const watching = settings?.watches.some((watch) => watch.thread_id === threadId && watch.enabled) ?? false;
  return <section className="notification-controls" aria-label="Conversation notifications">
    <button className="secondary-button" type="button" aria-pressed={watching} disabled={busy || demo || !settings || !threadId}
      onClick={() => void action(async () => { await api("/watch", "PUT", { threadId, enabled: !watching }); setMessage(watching ? "Conversation muted." : "Watching future runs until you mute this conversation."); })}>
      {watching ? "Mute this conversation" : "Watch this conversation"}
    </button>
    <p>{demo ? "Notification controls are disabled in this preview." : watching ? "Completion and available attention signals are watched across future runs." : "Watch is optional and stays on until you mute it."}</p>
    {allActive ? <p>All-conversation alerts are on, even for muted conversations. Your individual preference resumes when they end.</p> : null}
    {watching && !currentDevice ? <p>No notifications are enabled on this device yet.</p> : null}
    <p role="status">{busy ? "Saving notification settings…" : message}</p>
  </section>;
}

export function NotificationOverview({ demo, sessions = [], onOpenWatch, checkIn, collectorControls, onSettingsClose }: { demo: boolean; sessions?: AgentSession[]; onOpenWatch?: (watch: WatchedConversation) => void; checkIn?: ReactNode; collectorControls?: ReactNode; onSettingsClose?: () => void }) {
  const { automaticPaused } = useNotifications();
  const { settings, busy, message, setMessage, deviceId, setDeviceId, supported, currentDevice, allActive, action, enable } = useNotifications();
  const [expanded, setExpanded] = useState(false);
  const [duration, setDuration] = useState('60');
  const [panel, setPanel] = useState<'alerts' | 'watching' | 'settings' | null>(null);
  const watchesExpanded = panel === 'watching';
  const togglePanel = (next: 'alerts' | 'watching' | 'settings') => {
    if (next !== 'settings' || panel === next) onSettingsClose?.();
    setPanel(panel === next ? null : next);
    if (panel !== next && !demo) void action(async () => {});
  };
  const watches = demo ? sessions.slice(0, 2).map(session => ({ threadId: session.threadId ?? session.id, session }))
    : (settings?.watches ?? []).filter(watch => watch.enabled).map(watch => ({
      threadId: watch.thread_id,
      session: sessions.find(session => (session.threadId ?? session.id) === watch.thread_id)
        ?? mapLiveSessions({ sessions: watch.session ? [watch.session] : [], events: [] })[0],
    }));
  return <section className="notification-controls notification-overview compact-controls" aria-label="Dashboard controls">
    <div className="quick-controls" aria-label="Dashboard settings">
      <button type="button" aria-expanded={panel === 'alerts'} aria-controls="alert-settings" onClick={() => togglePanel('alerts')}>Alerts: {allActive ? 'On' : settings || demo ? 'Off' : 'Unknown'}</button>
      <button type="button" aria-expanded={watchesExpanded} aria-controls="watched-conversations" onClick={() => togglePanel('watching')}>Watching{settings || demo ? ` (${watches.length})` : ''}</button>
      <button type="button" aria-expanded={panel === 'settings'} aria-controls="dashboard-settings" onClick={() => togglePanel('settings')}>Settings</button>
    </div>
    <div className="quick-controls-status">{checkIn}{allActive ? <span>{settings?.allAlways ? 'Alerts always on' : `Alerts until ${new Date(settings!.allUntil!).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`}</span> : null}</div>
    <div id="alert-settings" className="quick-controls-panel" hidden={panel !== 'alerts'}>
    <div className="notification-overview-heading">
      <h2>All-conversation alerts</h2>
      <span className="notification-state">{allActive ? (settings?.allAlways ? 'Always on' : 'On temporarily') : 'Off'}</span>
    </div>
    <div className="all-notification-actions">
      <label htmlFor="notification-duration">Notify for
        <select id="notification-duration" value={settings?.allAlways && allActive ? 'always' : duration} disabled={busy || allActive || demo} onChange={event => setDuration(event.target.value)}>
          <option value={15}>15 minutes</option><option value={60}>1 hour</option><option value={240}>4 hours</option>
          <option value="midnight">Until midnight</option><option value="always">Always on</option>
        </select>
      </label>
      <button className="secondary-button" type="button" aria-pressed={allActive} disabled={busy || demo || !settings || (!allActive && (!settings.configured || !settings.devices.length))}
        onClick={() => void action(async () => {
          await api('/all', 'PUT', allActive ? { minutes: 0 } : notificationDuration(duration));
        })}>{allActive ? 'Turn Off' : 'Notify for all'}</button>
    </div>
    {allActive || duration === 'midnight' || duration === 'always' ? <p className="notification-summary">{allActive ? settings?.allAlways ? 'On until you turn it off, even with this page closed.' : `On until ${new Date(settings!.allUntil!).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}. Stops automatically, even with this page closed.` : duration === 'midnight' ? 'Stops at midnight in this device’s timezone.' : 'Stays on until you turn it off.'}</p> : null}
    {demo || !settings || !settings.devices.length ? <p className="notification-hint">{demo ? 'Notification controls are disabled in this preview.' : !settings ? (automaticPaused ? 'Automatic updates paused by Switchr. Open device settings to load them manually.' : 'Loading notification settings…') : 'Enable a device below before turning on all-conversation alerts.'}</p> : null}
    </div>
    {watchesExpanded ? <div id="watched-conversations">
      <h2>Watched conversations</h2>
      {demo ? <p>Sample watches for this preview.</p> : null}
      {!demo && !settings ? <p>Watch list unavailable. Close and reopen to retry.</p> : watches.length === 0 ? <p>No conversations watched.</p> : <ul className="watched-conversations-list">
        {watches.map(watch => <li key={watch.threadId}><button className="watch-details-button" type="button" onClick={() => onOpenWatch?.(watch)}>
          <span>{watch.session?.title ?? `Conversation ${watch.threadId}`}</span><span className="watch-details-label">View details</span>
        </button></li>)}
      </ul>}
    </div> : null}
    <div id="dashboard-settings" className="quick-controls-panel" hidden={panel !== 'settings'}>
    {collectorControls}
    <button className="text-button" type="button" aria-expanded={expanded} aria-controls="notification-device-settings" onClick={() => { setExpanded(!expanded); if (!demo) void action(async () => {}); }}>Notification device settings</button>
    {expanded ? <div id="notification-device-settings">
      <p>Completion, failure, and available attention alerts, including new conversations.</p>
      <p>All-conversation alerts go to all enabled devices and include muted conversations. Your individual watches stay unchanged. Alerts already sent cannot be recalled.</p>
      <p>On iPhone, add Status Watchr to your Home Screen from your browser’s Share menu. Open it there, then enable notifications.</p>
      <p>Lock-screen alerts contain no conversation titles. A finished run is not a guarantee the assignment is complete. Questions are not yet reliably detected.</p>
      {!settings?.configured && !demo ? <p>Server push setup is still required. Your watch preferences can be saved now.</p> : null}
      {!supported ? <p>This browser does not expose Web Push. Try the installed Home Screen app.</p> : null}
      <div className="notification-actions">
        <button className="secondary-button" type="button" disabled={busy || demo || !supported || !settings?.configured} onClick={() => void action(enable)}>{currentDevice ? "Reconnect this device" : "Enable this device"}</button>
        <button className="secondary-button" type="button" disabled={busy || !currentDevice || demo} onClick={() => void action(async () => { await api("/test", "POST", { id: deviceId }); setMessage("Push service accepted the test. Check your device; this does not confirm it was displayed."); })}>Send test notification</button>
      </div>
      {settings?.devices.map((device, index) => <div className="notification-device" key={device.id}>
        <span>{device.id === deviceId ? "This device" : `Device ${index + 1}`} · added {new Date(device.created_at).toLocaleDateString()}</span>
        <button className="text-button" type="button" disabled={busy} onClick={() => void action(async () => {
          await api("/unsubscribe", "POST", { id: device.id });
          if (device.id === deviceId) { localStorage.removeItem("statusWatchr.pushDevice"); setDeviceId(""); }
          setMessage("Device revoked. Pending deliveries are removed; a push already in flight cannot be recalled.");
        })}>Revoke</button>
      </div>)}
    </div> : null}
    </div>
    <p role="status">{busy ? "Saving notification settings…" : message}</p>
  </section>;
}
