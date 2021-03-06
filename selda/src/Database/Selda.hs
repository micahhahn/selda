{-# LANGUAGE OverloadedStrings, FlexibleInstances, UndecidableInstances #-}
-- | Selda is not LINQ, but they're definitely related.
--
--   Selda is a high-level EDSL for interacting with relational databases.
--   Please see <https://github.com/valderman/selda/> for a brief tutorial.
module Database.Selda
  ( -- * Running queries
    MonadIO (..), MonadSelda
  , SeldaT, Table, Query, Col, Res, Result
  , query, transaction, setLocalCache
    -- * Constructing queries
  , SqlType
  , Text, Cols, Columns
  , Order (..)
  , (:*:)(..)
  , select, selectValues
  , restrict, limit, order
  , ascending, descending
    -- * Expressions over columns
  , (.==), (./=), (.>), (.<), (.>=), (.<=), like
  , (.&&), (.||), not_
  , literal, int, float, text, true, false, null_
  , roundTo, length_, isNull
    -- * Converting between column types
  , round_, just, fromBool, fromInt, toString
    -- * Inner queries
  , Aggr, Aggregates, OuterCols, JoinCols, Inner, MinMax
  , leftJoin
  , aggregate, groupBy
  , count, avg, sum_, max_, min_
    -- * Modifying tables
  , Insert
  , insert, insert_, insertWithPK, def
  , update, update_
  , deleteFrom, deleteFrom_
    -- * Defining schemas
  , TableSpec, ColSpecs, ColSpec, TableName, ColName
  , NonNull, IsNullable, Nullable, NotNullable
  , Append (..), (:++:)
  , table, required, optional
  , primary, autoPrimary
    -- * Creating and dropping tables
  , createTable, tryCreateTable
  , dropTable, tryDropTable
    -- * Compiling and inspecting queries
  , OnError (..)
  , compile
  , compileCreateTable, compileDropTable
  , compileInsert, compileUpdate
    -- * Tuple convenience functions
  , Tup, Head
  , first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth
  ) where
import Data.Text (Text)
import Database.Selda.Backend
import Database.Selda.Column
import Database.Selda.Compile
import Database.Selda.Frontend
import Database.Selda.Inner
import Database.Selda.Query
import Database.Selda.Query.Type
import Database.Selda.SQL
import Database.Selda.SqlType
import Database.Selda.Table
import Database.Selda.Table.Compile
import Database.Selda.Types
import Database.Selda.Unsafe
import Control.Exception (throw)

-- | Any column type that can be used with the 'min_' and 'max_' functions.
class SqlType a => MinMax a
instance {-# OVERLAPPABLE #-} (SqlType a, Num a) => MinMax a
instance MinMax Text
instance MinMax a => MinMax (Maybe a)

(.==), (./=), (.>), (.<), (.>=), (.<=) :: SqlType a => Col s a -> Col s a -> Col s Bool
(.==) = liftC2 $ BinOp Eq
(./=) = liftC2 $ BinOp Neq
(.>)  = liftC2 $ BinOp Gt
(.<)  = liftC2 $ BinOp Lt
(.>=) = liftC2 $ BinOp Gte
(.<=) = liftC2 $ BinOp Lte
infixl 4 .==
infixl 4 ./=
infixl 4 .>
infixl 4 .<
infixl 4 .>=
infixl 4 .<=

-- | Is the given column null?
isNull :: Col s (Maybe a) -> Col s Bool
isNull = liftC $ UnOp IsNull

(.&&), (.||) :: Col s Bool -> Col s Bool -> Col s Bool
(.&&) = liftC2 $ BinOp And
(.||) = liftC2 $ BinOp Or
infixr 3 .&&
infixr 2 .||

-- | Ordering for 'order'.
ascending, descending :: Order
ascending = Asc
descending = Desc

-- | The default value for a column during insertion.
--   For an auto-incrementing primary key, the default value is the next key.
--
--   Using @def@ in any other context than insertion results in a runtime error.
--   Likewise, if @def@ is given for a column that does not have a default
--   value, the insertion will fail.
def :: SqlType a => a
def = throw DefaultValueException

-- | Lift a non-nullable column to a nullable one.
--   Useful for creating expressions over optional columns:
--
-- > people :: Table (Text :*: Int :*: Maybe Text)
-- > people = table "people" $ required "name" ¤ required "age" ¤ optional "pet"
-- >
-- > peopleWithCats = do
-- >   name :*: _ :*: pet <- select people
-- >   restrict (pet .== just "cat")
-- >   return name
just :: SqlType a => Col s a -> Col s (Maybe a)
just = cast

-- | SQL NULL, at any type you like.
null_ :: SqlType a => Col s (Maybe a)
null_ = literal Nothing

-- | Specialization of 'literal' for integers.
int :: Int -> Col s Int
int = literal

-- | Specialization of 'literal' for doubles.
float :: Double -> Col s Double
float = literal

-- | Specialization of 'literal' for text.
text :: Text -> Col s Text
text = literal

-- | True and false boolean literals.
true, false :: Col s Bool
true = literal True
false = literal False

-- | The SQL @LIKE@ operator; matches strings with @%@ wildcards.
--   For instance:
--
-- > "%gon" `like` "dragon" .== true
like :: Col s Text -> Col s Text -> Col s Bool
like = liftC2 $ BinOp Like
infixl 4 `like`

-- | The number of non-null values in the given column.
count :: SqlType a => Col s a -> Aggr s Int
count = aggr "COUNT"

-- | The average of all values in the given column.
avg :: (SqlType a, Num a) => Col s a -> Aggr s a
avg = aggr "AVG"

-- | The greatest value in the given column. Texts are compared lexically.
max_ :: MinMax a => Col s a -> Aggr s a
max_ = aggr "MAX"

-- | The smallest value in the given column. Texts are compared lexically.
min_  :: MinMax a => Col s a -> Aggr s a
min_ = aggr "MIN"

-- | Sum all values in the given column.
sum_ :: (SqlType a, Num a) => Col s a -> Aggr s a
sum_ = aggr "SUM"

-- | Round a value to the nearest integer. Equivalent to @roundTo 0@.
round_ :: Num a => Col s Double -> Col s a
round_ = fun "ROUND"

-- | Round a column to the given number of decimals places.
roundTo :: Col s Int -> Col s Double -> Col s Double
roundTo = flip $ fun2 "ROUND"

-- | Calculate the length of a string column.
length_ :: Col s Text -> Col s Int
length_ = fun "LENGTH"

-- | Boolean negation.
not_ :: Col s Bool -> Col s Bool
not_ = liftC $ UnOp Not

-- | Convert a boolean column to any numeric type.
fromBool :: (SqlType a, Num a) => Col s Bool -> Col s a
fromBool = cast

-- | Convert an integer column to any numeric type.
fromInt :: (SqlType a, Num a) => Col s Int -> Col s a
fromInt = cast

-- | Convert any column to a string.
toString :: Col s a -> Col s String
toString = cast
