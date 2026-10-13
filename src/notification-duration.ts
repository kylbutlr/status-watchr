/** Calendar arithmetic uses the activating device's local timezone, including DST. */
export function notificationDuration(choice: string, now = new Date()) {
  if (choice === 'always') return { mode: 'always' };
  if (choice === 'midnight') {
    const midnight = new Date(now);
    midnight.setHours(24, 0, 0, 0);
    return { mode: 'midnight', until: midnight.toISOString() };
  }
  return { minutes: Number(choice) };
}
