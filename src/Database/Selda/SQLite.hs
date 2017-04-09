{-# LANGUAGE GADTs #-}
-- | SQLite3 backend for Selda.
module Database.Selda.SQLite (withSQLite) where
import Database.Selda
import Database.Selda.Backend
import Database.SQLite3
import Data.Text (pack)
import Control.Monad.Catch
import Control.Concurrent

-- | Perform the given computation over an SQLite database.
--   The database is guaranteed to be closed when the computation terminates.
withSQLite :: (MonadIO m, MonadMask m) => FilePath -> SeldaT m a -> m a
withSQLite file m = do
  lock <- liftIO $ newMVar ()
  db <- liftIO $ open (pack file)
  runSeldaT m (sqliteBackend lock db) `finally` liftIO (close db)

sqliteBackend :: MVar () -> Database -> SeldaBackend
sqliteBackend lock db = SeldaBackend
  { runStmt          = \q ps -> snd <$> sqliteQueryRunner lock db q ps
  , runStmtWithRowId = \q ps -> fst <$> sqliteQueryRunner lock db q ps
  }

sqliteQueryRunner :: MVar () -> Database -> QueryRunner (Int, (Int, [[SqlValue]]))
sqliteQueryRunner lock db qry params = do
    stm <- prepare db qry
    go stm `finally` finalize stm
  where
    go stm = do
      takeMVar lock
      rid <- flip finally (putMVar lock ()) $ do
        bind stm [toSqlData p | Param p <- params]
        lastInsertRowId db
      rows <- getRows stm []
      cs <- changes db
      return (fromIntegral rid, (cs, [map fromSqlData r | r <- rows]))

    getRows s acc = do
      res <- step s
      case res of
        Row -> do
          cs <- columns s
          getRows s (cs : acc)
        _ -> do
          return $ reverse acc

toSqlData :: Lit a -> SQLData
toSqlData (LitI i)    = SQLInteger $ fromIntegral i
toSqlData (LitD d)    = SQLFloat d
toSqlData (LitS s)    = SQLText s
toSqlData (LitB b)    = SQLInteger $ if b then 1 else 0
toSqlData (LitNull)   = SQLNull
toSqlData (LitJust x) = toSqlData x

fromSqlData :: SQLData -> SqlValue
fromSqlData (SQLInteger i) = SqlInt $ fromIntegral i
fromSqlData (SQLFloat f)   = SqlFloat f
fromSqlData (SQLText s)    = SqlString s
fromSqlData (SQLBlob _)    = error "Selda doesn't support blobs"
fromSqlData SQLNull        = SqlNull
