-- =============================================================================
-- messages テーブル定義（Azure SQL Database / T-SQL）
-- 試合（match_id）ごとのファンの応援メッセージを保存する。
--
-- PostgreSQL スキーマからの変換ルール:
--   BIGSERIAL    -> BIGINT IDENTITY(1,1)
--   TEXT         -> NVARCHAR(MAX)
--   VARCHAR(n)   -> NVARCHAR(n)        （日本語を扱うため Unicode 化）
--   TIMESTAMPTZ  -> DATETIME2
--   now()        -> SYSUTCDATETIME()   （UTC で保存）
--
-- 注意:
--   SQL Server では NVARCHAR(MAX) を索引キー列に指定できない。
--   インデックス対象の match_id は TEXT だが、索引を維持するため
--   NVARCHAR(450)（索引キーの上限 900 バイト = 450 文字）に変換する。
--   索引対象外の name は規則どおり NVARCHAR(MAX) とする。
-- =============================================================================

IF OBJECT_ID(N'dbo.messages', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.messages (
        id          BIGINT         IDENTITY(1,1) NOT NULL,  -- BIGSERIAL
        match_id    NVARCHAR(450)  NOT NULL,                -- TEXT（索引キーのため長さ制限）
        name        NVARCHAR(MAX)  NOT NULL,                -- TEXT
        body        NVARCHAR(200)  NOT NULL,                -- VARCHAR(200)
        created_at  DATETIME2      NOT NULL                 -- TIMESTAMPTZ
            CONSTRAINT DF_messages_created_at DEFAULT SYSUTCDATETIME(),  -- now()
        CONSTRAINT PK_messages PRIMARY KEY (id)
    );
END;
GO

-- match_id での絞り込み・新しい順取得を高速化するためのインデックス。
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'idx_messages_match_id_created_at'
      AND object_id = OBJECT_ID(N'dbo.messages')
)
BEGIN
    CREATE INDEX idx_messages_match_id_created_at
        ON dbo.messages (match_id, created_at DESC);
END;
GO
