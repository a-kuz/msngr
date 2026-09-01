-- Stories. Not end-to-end encrypted: who may see one is an access rule, not a
-- key, which is what makes a public link possible at all. `frames` is the JSON
-- the composer built — the media ids and the text over them.
CREATE TABLE stories (
  id TEXT PRIMARY KEY,
  author_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  frames TEXT NOT NULL,
  -- everyone: anyone who has the author's handle; contacts: the people the
  -- author has a direct chat with
  audience TEXT NOT NULL,
  -- the public link, when the creator asked for one, and whether it was revoked
  link_code TEXT,
  link_revoked INTEGER NOT NULL DEFAULT 0,
  taken_down INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_stories_author ON stories(author_id, created_at);
CREATE UNIQUE INDEX idx_stories_link ON stories(link_code);

-- Who watched. Belongs to the creator alone: the public page never reads it.
CREATE TABLE story_views (
  story_id TEXT NOT NULL,
  viewer_id TEXT NOT NULL,
  seen_at INTEGER NOT NULL,
  PRIMARY KEY (story_id, viewer_id)
);
