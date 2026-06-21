-- messages テーブル定義（Azure SQL Database / T-SQL）
-- 試合（match_id）ごとのファンの応援メッセージを保存する。
-- PostgreSQL からの変換点:
--   BIGSERIAL      -> BIGINT IDENTITY(1,1)
--   TEXT           -> NVARCHAR(...)
--   VARCHAR(200)   -> NVARCHAR(200)
--   TIMESTAMPTZ    -> DATETIMEOFFSET
--   now()          -> SYSDATETIMEOFFSET()
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = N'messages')
BEGIN
    CREATE TABLE messages (
        id          BIGINT         IDENTITY(1,1) PRIMARY KEY,
        match_id    NVARCHAR(100)  NOT NULL,
        name        NVARCHAR(100)  NOT NULL,
        body        NVARCHAR(200)  NOT NULL,
        created_at  DATETIMEOFFSET NOT NULL CONSTRAINT DF_messages_created_at DEFAULT SYSDATETIMEOFFSET()
    );
END;
GO

-- match_id での絞り込み・新しい順取得を高速化するためのインデックス。
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'idx_messages_match_id_created_at')
BEGIN
    CREATE INDEX idx_messages_match_id_created_at
        ON messages (match_id, created_at DESC);
END;
GO
