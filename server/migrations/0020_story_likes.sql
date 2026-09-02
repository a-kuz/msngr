-- A like on a story. The author alone sees who liked, next to who watched;
-- a viewer sees only their own heart.
CREATE TABLE story_likes (
  story_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  liked_at INTEGER NOT NULL,
  PRIMARY KEY (story_id, user_id)
);
