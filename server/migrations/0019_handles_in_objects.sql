-- The handle's owner and the quarantine after a rename live in the handle's
-- own Durable Object (HandleDO), and people search reads the DirectoryDO index.
DROP TABLE IF EXISTS released_usernames;
