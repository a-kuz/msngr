-- User search matches display names case-insensitively through a stored
-- lowercase column folded in JS: SQLite's LOWER folds ASCII only.
ALTER TABLE users ADD COLUMN display_name_lc TEXT NOT NULL DEFAULT '';
UPDATE users SET display_name_lc = LOWER(display_name);
