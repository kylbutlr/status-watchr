-- Private single-owner only. Apply after a verified backup and before deploying reply previews.
begin;
alter table notification_deliveries add column if not exists reply_preview text;
commit;
