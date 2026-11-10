-- Group state kept beside the groups table, whose INSERT lists every column.
CREATE TABLE IF NOT EXISTS group_extras (
  master_key BLOB NOT NULL PRIMARY KEY,
  announcements_only INTEGER NOT NULL DEFAULT 0,
  banned_members TEXT NOT NULL DEFAULT '[]',
  terminated INTEGER NOT NULL DEFAULT 0
);
