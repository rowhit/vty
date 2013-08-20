-- Copyright Corey O'Connor
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{- | A picture is translated into a sequences of state changes and character spans.
 - State changes are currently limited to new attribute values. The attribute is applied to all
 - following spans. Including spans of the next row.  The nth element of the sequence represents the
 - nth row (from top to bottom) of the picture to render.
 -
 - A span op sequence will be defined for all rows and columns (and no more) of the region provided
 - with the picture to spans_for_pic.
 -
 - todo: Partition attribute changes into multiple categories according to the serialized
 - representation of the various attributes.
 -}
module Graphics.Vty.Span
    where

import Graphics.Vty.DisplayRegion
import Graphics.Vty.Image

import Data.Vector (Vector)
import qualified Data.Vector as Vector

import qualified Data.Text.Lazy as TL

-- | This represents an operation on the terminal. Either an attribute change or the output of a
-- text string.
data SpanOp =
    -- | a span of UTF-8 text occupies a specific number of screen space columns. A single UTF
    -- character does not necessarially represent 1 colunm. See Codec.Binary.UTF8.Width
    -- TextSpan [Attr] [output width in columns] [number of characters] [data]
      TextSpan 
      { text_span_attr :: !Attr
      , text_span_output_width :: !Int
      , text_span_char_width :: !Int
      , text_span_data :: DisplayText
      }
    -- | Skips the given number of columns
    -- A skip is transparent.... maybe? I am not sure how attribute changes interact.
    -- todo: separate from this type.
    | Skip !Int
    -- | Marks the end of a row. specifies how many columns are remaining. These columns will not be
    -- explicitly overwritten with the span ops. The terminal is require to assure the remaining
    -- columns are clear.
    -- todo: separate from this type.
    | RowEnd !Int
    deriving Eq

-- | vector of span operations. executed in succession. This represents the operations required to
-- render a row of the terminal. The operations in one row may effect subsequent rows.
-- EG: Setting the foreground color in one row will effect all subsequent rows until the foreground
-- color is changed.
type SpanOps = Vector SpanOp

drop_ops :: Int -> SpanOps -> SpanOps
drop_ops w = snd . split_ops_at w

split_ops_at :: Int -> SpanOps -> (SpanOps, SpanOps)
split_ops_at in_w in_ops = split_ops_at' in_w in_ops
    where
        split_ops_at' 0 ops = (Vector.empty, ops)
        split_ops_at' remaining_columns ops = case Vector.head ops of
            t@(TextSpan {}) -> undefined
            Skip w -> if remaining_columns >= w
                then let (pre,post) = split_ops_at' (remaining_columns - w) (Vector.tail ops)
                     in (Vector.cons (Skip w) pre, post)
                else ( Vector.singleton $ Skip remaining_columns
                     , Vector.cons (Skip (w - remaining_columns)) (Vector.tail ops)
                     )
            RowEnd _ -> error "cannot split ops containing a row end"
        

-- | vector of span operation vectors for display. One per row of the output region.
type DisplayOps = Vector SpanOps

instance Show SpanOp where
    show (TextSpan attr ow cw _) = "TextSpan(" ++ show attr ++ ")(" ++ show ow ++ ", " ++ show cw ++ ")"
    show (Skip ow) = "Skip(" ++ show ow ++ ")"
    show (RowEnd ow) = "RowEnd(" ++ show ow ++ ")"

-- | Number of columns the DisplayOps are defined for
--
-- All spans are verified to define same number of columns. See: VerifySpanOps
display_ops_columns :: DisplayOps -> Int
display_ops_columns ops 
    | Vector.length ops == 0 = 0
    | otherwise              = Vector.length $ Vector.head ops

-- | Number of rows the DisplayOps are defined for
display_ops_rows :: DisplayOps -> Int
display_ops_rows ops = Vector.length ops

effected_region :: DisplayOps -> DisplayRegion
effected_region ops = DisplayRegion (display_ops_columns ops) (display_ops_rows ops)

-- | The number of columns a SpanOps effects.
span_ops_effected_columns :: SpanOps -> Int
span_ops_effected_columns in_ops = Vector.foldl' span_ops_effected_columns' 0 in_ops
    where 
        span_ops_effected_columns' t (TextSpan _ w _ _ ) = t + w
        span_ops_effected_columns' t (Skip w) = t + w
        span_ops_effected_columns' t (RowEnd w) = t + w

-- | The width of a single SpanOp in columns
span_op_has_width :: SpanOp -> Maybe (Int, Int)
span_op_has_width (TextSpan _ ow cw _) = Just (cw, ow)
span_op_has_width (Skip ow) = Just (ow,ow)
span_op_has_width (RowEnd ow) = Just (ow,ow)

-- | returns the number of columns to the character at the given position in the span op
columns_to_char_offset :: Int -> SpanOp -> Int
columns_to_char_offset cx (TextSpan _ _ _ utf8_str) =
    let str = TL.unpack utf8_str
    in wcswidth (take cx str)
columns_to_char_offset cx (Skip _) = cx
columns_to_char_offset cx (RowEnd _) = cx

