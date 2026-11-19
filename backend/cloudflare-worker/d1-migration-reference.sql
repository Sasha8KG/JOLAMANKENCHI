-- Выполнить один раз в D1 SQL Console до публикации нового Worker.
ALTER TABLE orders ADD COLUMN firebase_synced_at INTEGER;
