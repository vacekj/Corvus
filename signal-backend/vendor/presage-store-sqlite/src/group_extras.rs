//! Group fields newer than the `groups` table: announcements-only, banned
//! members, terminated. Plain (not compile-time checked) queries.

use std::collections::HashMap;

use presage::model::groups::{BannedMember, Group};
use sqlx::{Row, SqliteConnection, SqlitePool};

use crate::SqliteStoreError;

pub(crate) struct GroupExtras {
    announcements_only: bool,
    banned_members: Vec<BannedMember>,
    terminated: bool,
}

impl GroupExtras {
    pub(crate) fn of(group: &Group) -> Self {
        Self {
            announcements_only: group.announcements_only,
            banned_members: group.banned_members.clone(),
            terminated: group.terminated,
        }
    }

    pub(crate) fn apply(self, group: &mut Group) {
        group.announcements_only = self.announcements_only;
        group.banned_members = self.banned_members;
        group.terminated = self.terminated;
    }

    fn from_row(row: &sqlx::sqlite::SqliteRow) -> Result<(Vec<u8>, Self), SqliteStoreError> {
        let banned: String = row.try_get("banned_members")?;
        Ok((
            row.try_get("master_key")?,
            Self {
                announcements_only: row.try_get("announcements_only")?,
                banned_members: serde_json::from_str(&banned)?,
                terminated: row.try_get("terminated")?,
            },
        ))
    }

    pub(crate) async fn save(
        &self,
        connection: &mut SqliteConnection,
        master_key: &[u8],
    ) -> Result<(), SqliteStoreError> {
        sqlx::query("INSERT OR REPLACE INTO group_extras VALUES (?, ?, ?, ?)")
            .bind(master_key)
            .bind(self.announcements_only)
            .bind(serde_json::to_string(&self.banned_members)?)
            .bind(self.terminated)
            .execute(connection)
            .await?;
        Ok(())
    }

    pub(crate) async fn load(
        db: &SqlitePool,
        master_key: &[u8],
    ) -> Result<Option<Self>, SqliteStoreError> {
        sqlx::query("SELECT * FROM group_extras WHERE master_key = ?")
            .bind(master_key)
            .fetch_optional(db)
            .await?
            .map(|row| Self::from_row(&row).map(|(_, extras)| extras))
            .transpose()
    }

    pub(crate) async fn load_all(
        db: &SqlitePool,
    ) -> Result<HashMap<Vec<u8>, Self>, SqliteStoreError> {
        sqlx::query("SELECT * FROM group_extras")
            .fetch_all(db)
            .await?
            .iter()
            .map(Self::from_row)
            .collect()
    }

    pub(crate) async fn clear(connection: &mut SqliteConnection) -> Result<(), SqliteStoreError> {
        sqlx::query("DELETE FROM group_extras")
            .execute(connection)
            .await?;
        Ok(())
    }
}
