module CodeWorld.FMIDUE where

import Prelude (Double)
import CodeWorld.Color
import CodeWorld.Picture
import Data.Text (Text)
import GHC.Stack

-- | A list of Points.
type Points = [Point]

-- | Unicode text. 
type String = Text

-- | A picture rotated by this angle about the origin.
--
-- Angles are in radians.
rotate :: HasCallStack => Double -> Picture -> Picture
rotate = rotated

-- | A picture drawn translated in these directions.
move :: HasCallStack => Double -> Double -> Picture -> Picture
move = translated

-- | A picture drawn entirely in this color.
color :: HasCallStack => Color -> Picture -> Picture
color = colored

-- | A rendering of text characters.
print :: HasCallStack => String -> Picture
print = lettering

-- | A picture scaled by these factors in the x and y directions.  Scaling
-- by a negative factor also reflects across that axis.
scale :: HasCallStack => Double -> Double -> Picture -> Picture
scale = scaled

-- | A thin sequence of line segments, with these points as endpoints
path :: HasCallStack => Points -> Picture
path = polyline