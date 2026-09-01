-- A bot is an account without keys: it has no device of its own to encrypt
-- from, so everything it takes part in travels in the clear. `bot_owner` names
-- the person who made it and is what tells a bot from a person; `bot_commands`
-- is the list the input offers after «/».
ALTER TABLE users ADD COLUMN bot_owner TEXT;
ALTER TABLE users ADD COLUMN bot_commands TEXT;
CREATE INDEX idx_users_bot_owner ON users(bot_owner);
