{-# LANGUAGE NoImplicitPrelude #-}
module Internal.FMIDUE where

import Internal.Num
import Internal.Picture
import Internal.Color
import Internal.Text
import GHC.Stack

-- | A list of Points.
type Points = [Point]

-- | Unicode text. 
type String = Text

-- | A picture rotated by this angle about the origin.
--
-- Angles are in radians.
rotate :: HasCallStack => (Picture, Number) -> Picture
rotate = rotated

-- | A picture drawn at the given coordinates.
move :: HasCallStack => (Picture, Number, Number) -> Picture
move = translated

-- | A picture drawn entirely in this color.
color :: HasCallStack => (Picture, Color) -> Picture
color = colored

-- | A rendering of text characters.
print :: HasCallStack => String -> Picture
print = lettering

-- | A picture scaled by these factors in the x and y directions.  Scaling
-- by a negative factor also reflects across that axis.
scale :: HasCallStack => (Picture, Number, Number) -> Picture
scale = scaled

-- | A thin sequence of line segments, with these points as endpoints
path :: HasCallStack => Points -> Picture
path = polyline
