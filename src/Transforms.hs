{-# LANGUAGE TemplateHaskell, StandaloneDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveGeneric #-}

module Transforms where

import Utils
import Debug.Trace
import           Data.List                          (nub, sort, findIndex, find, maximumBy, foldl')
import qualified Data.Map.Strict as M

import GHC.Generics
import Data.Aeson (FromJSON, ToJSON, toJSON)

-- a, b, c, d, e, f as here:
-- https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/transform
data HMatrix a = HMatrix {
     xScale :: a, -- a
     xSkew :: a, -- c -- What are c and b called?
     ySkew :: a, -- b
     yScale :: a, -- d
     dx     :: a, -- e
     dy     :: a  -- f
} deriving (Generic, Eq)

instance Show a => Show (HMatrix a) where
         show m = "[ " ++ show (xScale m) ++ " " ++ show (xSkew m) ++ " " ++ show (dx m) ++ " ]\n" ++
                  "  " ++ show (ySkew m) ++ " " ++ show (yScale m) ++ " " ++ show (dy m) ++ "  \n" ++
                  "  0.0 0.0 1.0 ]"

instance (FromJSON a) => FromJSON (HMatrix a)
instance (ToJSON a)   => ToJSON (HMatrix a)

idH :: (Autofloat a) => HMatrix a
idH = HMatrix {
    xScale = 1,
    xSkew = 0,
    ySkew = 0,
    yScale = 1,
    dx = 0,
    dy = 0
}

-- First row, then second row
hmToList :: (Autofloat a) => HMatrix a -> [a]
hmToList m = [ xScale m, xSkew m, dx m, ySkew m, yScale m, dy m ]

listToHm :: (Autofloat a) => [a] -> HMatrix a
listToHm l = if length l /= 6 then error "wrong length list for hmatrix"
             else HMatrix { xScale = l !! 0, xSkew = l !! 1, dx = l !! 2,
                            ySkew = l !! 3, yScale = l !! 4, dy = l !! 5 }

hmDiff :: (Autofloat a) => HMatrix a -> HMatrix a -> a
hmDiff t1 t2 = let (l1, l2) = (hmToList t1, hmToList t2) in
               norm $ l1 -. l2

applyTransform :: (Autofloat a) => HMatrix a -> Pt2 a -> Pt2 a
applyTransform m (x, y) = (x * xScale m + y * xSkew m + dx m, x * ySkew m + y * yScale m + dy m)

infixl ##
(##) :: (Autofloat a) => HMatrix a -> Pt2 a -> Pt2 a
(##) = applyTransform

-- General functions to work with transformations

-- Do t2, then t1. That is, multiply two homogeneous matrices: t1 * t2
composeTransform :: (Autofloat a) => HMatrix a -> HMatrix a -> HMatrix a
composeTransform t1 t2 = HMatrix { xScale = xScale t1 * xScale t2 + xSkew t1  * ySkew t2,
                                   xSkew  = xScale t1 * xSkew t2  + xSkew t1  * yScale t2,
                                   ySkew  =  ySkew t1 * xScale t2 + yScale t1 * ySkew t2,
                                   yScale =  ySkew t1 * xSkew t2  + yScale t1 * yScale t2,
                                   dx     = xScale t1 * dx t2 + xSkew t1 * dy t2 + dx t1,
                                   dy     = yScale t1 * dy t2 + ySkew t1 * dx t2 + dy t1 }
-- TODO: test that this gives expected results for two scalings, translations, rotations, etc.

infixl 7 #
(#) :: (Autofloat a) => HMatrix a -> HMatrix a -> HMatrix a
(#) = composeTransform

-- Compose all the transforms in RIGHT TO LEFT order:
-- [t1, t2, t3] means "do t3, then do t2, then do t1" or "t1 * t2 * t3"
composeTransforms :: (Autofloat a) => [HMatrix a] -> HMatrix a
composeTransforms ts = foldr composeTransform idH ts

-- Specific transformations

rotationM :: (Autofloat a) => a -> HMatrix a
rotationM radians = idH { xScale = cos radians, 
                          xSkew = -(sin radians),
                          ySkew = sin radians,
                          yScale = cos radians
                       }

translationM :: (Autofloat a) => Pt2 a -> HMatrix a
translationM (x, y) = idH { dx = x, dy = y }

scalingM :: (Autofloat a) => Pt2 a -> HMatrix a
scalingM (cx, cy) = idH { xScale = cx, yScale = cy }

rotationAboutM :: (Autofloat a) => a -> Pt2 a -> HMatrix a
rotationAboutM radians (x, y) = 
    -- Make the new point the new origin, do a rotation, then translate back
    composeTransforms [translationM (x, y), rotationM radians, translationM (-x, -y)]

shearingX :: (Autofloat a) => a -> HMatrix a
shearingX lambda = idH { xSkew = lambda }

shearingY :: (Autofloat a) => a -> HMatrix a
shearingY lambda = idH { ySkew = lambda }

------ Solve for final parameters

-- See PR for documentation
-- Note: returns angle in range [0, 2pi)
paramsOf :: (Autofloat a) => HMatrix a -> (a, a, a, a, a) -- There could be multiple solutions
paramsOf m = let (sx, sy) = (norm [xScale m, ySkew m], norm [xSkew m, yScale m]) in -- Ignore negative scale factors
             let theta = atan (ySkew m / (xScale m + epsd)) in -- Prevent atan(0/0) = NaN
             -- atan returns an angle in [-pi, pi]
             (sx, sy, theta, dx m, dy m)

paramsToMatrix :: (Autofloat a) => (a, a, a, a, a) -> HMatrix a
paramsToMatrix (sx, sy, theta, dx, dy) = -- scale then rotate then translate
               composeTransforms [translationM (dx, dy), rotationM theta, scalingM (sx, sy)]

toParallelogram :: (Autofloat a) => (a, a, a, a, a, a) -> HMatrix a
toParallelogram (w, h, rotation, x, y, shearAngle) =
                if shearAngle < 10**(-5) then error "shearAngle can't be 0, tangent will NaN" else
                composeTransforms [translationM (x, y),
                                   rotationM rotation,

                                   -- translationM (-w/2, -h/2),
                                   shearingX (1 / tan shearAngle),
                                   -- translationM (w/2, h/2),

                                   scalingM (w, h)
                                  ]

unitSq :: (Autofloat a) => [Pt2 a]
unitSq = [(0.5, 0.5), (-0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)]

circlePoly :: (Autofloat a) => a -> [Pt2 a]
circlePoly r = let 
-- currently doesn't use r, so that #sides remains the same throughout opt.
-- TODO: might want to depend on radius of the original circle in some way?
    sides = max 8 $ floor (64 / 4.0)
    indices = [0..sides-1]
    angles = map (\i -> (r2f i) / (r2f sides) * 2.0 * pi) indices
    pts = map (\a -> (cos a, sin a)) angles
    in pts

-- Sample a circle about the origin with some density according to its radius
sampleUnitCirc :: (Autofloat a) => a -> [Pt2 a]
sampleUnitCirc r = if r < 0.01 then [(0, 0)] else []

testTriangle :: (Autofloat a) => [Pt2 a]
testTriangle = [(0, 0), (100, 0), (50, 50)]

testNonconvex :: (Autofloat a) => [Pt2 a]
testNonconvex = [(0, 0), (100, 0), (50, 50), (100, 100), (0, 100)]

transformPoly :: (Autofloat a) => HMatrix a -> Polygon a -> Polygon a
transformPoly m (blobs, holes) = (map (map (applyTransform m)) blobs, map (map (applyTransform m)) holes)

transformSimplePoly :: (Autofloat a) => HMatrix a -> [Pt2 a] -> [Pt2 a]
transformSimplePoly m = map (applyTransform m)

-- Pointing to the right. Note: doesn't try to approximate the "inset" part of the arrowhead
rtArrowheadPoly :: (Autofloat a) => a -> [Pt2 a]
rtArrowheadPoly c = let x = 2 * c in -- c is the thickness of the line
                    let twox = x*2 in
              [(-x, x/4), -- Stem top
              (-twox, twox), -- Top left
              (twox, 0), -- Point of arrownead
              (-twox, -twox), -- Bottom left
              (-x, -x/4)] -- Stem bottom

ltArrowheadPoly :: (Autofloat a) => a -> [Pt2 a]
ltArrowheadPoly c = reverse $ map flipX $ rtArrowheadPoly c
                where flipX (x, y) = (-x, y)
                -- Reverse so the line polygon can join the stem bottom with the stem bottom

-- | Make a rectangular polygon of a line segment, accounting for its thickness and arrowheads
-- (Is this usable with autodiff?)
extrude :: (Autofloat a) => a -> Pt2 a -> Pt2 a -> Bool -> Bool -> [Pt2 a]
extrude c x y leftArr rightArr = 
     let dir = normalize' (y -: x)
         normal = rot90 dir -- normal vector to the line segment
         offset = (c / 2) *: normal -- find offset for each endpoint

         halfLen = mag (y -: x) / 2.0 -- Calculate arrowhead position
         trLeft = (-halfLen) *: dir
         trRight = halfLen *: dir

         left = if leftArr 
                then translate2 trLeft (ltArrowheadPoly c)
                else [x -: offset, x +: offset] -- Note: order matters for making the polygon
         right = if rightArr
                 then translate2 trRight (rtArrowheadPoly c)
                 else [y +: offset, y -: offset] 
     in left ++ right

------ Energies on polygons ------

---- some helpers below ----

type LineSeg a = (Pt2 a, Pt2 a)
type Blob a = [Pt2 a] -- temporary type for polygon. Connected, no holes
-- A list of positive shapes (regions) and a list of negative shapes (holes)
-- TODO: assuming that the positive shapes don't overlap and the negative shapes don't overlap (check this)
type Polygon a = ([Blob a], [Blob a])

emptyPoly :: Polygon a
emptyPoly = ([], [])

toPoly :: [Pt2 a] -> Polygon a
toPoly pts = ([pts], [])

posInf :: Autofloat a => a
posInf = 1 / 0

negInf :: Autofloat a => a
negInf = -1 / 0

-- input point, query parametric t
gettPS :: Autofloat a => Pt2 a -> LineSeg a -> a
gettPS p (a,b) = let
    v_ab = b -: a
    projl = v_ab `dotv` (p -: a)
    in projl / (magsq $ a -: b) -- TODO: doublecheck correctness?? norm or normsq?

normS :: Autofloat a => LineSeg a -> Pt2 a
normS (p1, p2) = normalize' $ rot90 $ p2 -: p1

-- test if two segments intersect. Doesn't calculate for ix point though.
ixSS :: Autofloat a => LineSeg a -> LineSeg a -> Bool
ixSS (a,b) (c,d) = let
    ncd = rot90 $ d -: c
    a_cd = ncd `dotv` (a -: c)
    b_cd = ncd `dotv` (b -: c)
    nab = rot90 $ b -: a
    c_ab = nab `dotv` (c -: a)
    d_ab = nab `dotv` (d -: a)
    in ((a_cd>=0&&b_cd<=0) || (a_cd<=0&&b_cd>=0)) && 
       ((c_ab>=0&&d_ab<=0) || (c_ab<=0&&d_ab>=0))

getSegmentsB :: Blob a -> [LineSeg a]
getSegmentsB pts = let 
    lastInd = length pts - 1
    f x = if x==lastInd then (pts!!lastInd, pts!!0) else (pts!!x, pts!!(x+1))
    in map f [0..lastInd]

getSegmentsG :: Polygon a -> [LineSeg a]
getSegmentsG (bds, hs) = let
    bdsegments = map (\b->getSegmentsB b) bds
    hsegments = map (\h->getSegmentsB h) hs
    in concat [concat bdsegments, concat hsegments]

-- works well when point not on boundary (otherwise handled separately as edge case.)
isInB :: Autofloat a => Blob a -> Pt2 a -> Bool
isInB pts (x0,y0) = {-if (dsqBP pts (x0,y0) 0) < epsd then True else -} let
    diffp = map (\(x,y)->(x-x0,y-y0)) pts
    getAngle (x,y) = atan2 y x 
    sweeps = map (\(p1,p2)->(getAngle p2)-(getAngle p1)) (getSegmentsB diffp)
    adjust sweep = 
        if sweep>pi then sweep-2*pi
        else if sweep<(-pi) then 2*pi+sweep
        else sweep
    sweepAdjusted = map adjust sweeps
    -- if inside pos poly, res would be 2*pi,
    -- if inside neg poly, res would be -2*pi,
    -- else res would be 0
    res = foldl' (+) 0.0 sweepAdjusted
    in res>pi || res<(-pi) 

isInG :: Autofloat a => Polygon a -> Pt2 a -> Bool
isInG (bds, hs) p = let
    inb = foldl (||) False $ map (\b->isInB b p) bds
    inh = foldl (||) False $ map (\h->isInB h p) hs
    in (inb) && (not inh)

getBBox :: Autofloat a => Blob a -> (Pt2 a, Pt2 a)
getBBox pts = let
    foldfn :: Autofloat a => (Pt2 a, Pt2 a) -> Pt2 a -> (Pt2 a, Pt2 a)
    foldfn ((xlo,ylo), (xhi,yhi)) (x, y) = 
        ( (min xlo x, min ylo y), (max xhi x, max yhi y) )
    in foldl' foldfn ((posInf, posInf), (negInf, negInf)) pts

inBBox :: Autofloat a => (Pt2 a, Pt2 a) -> Pt2 a -> Bool
inBBox ((xlo, ylo), (xhi, yhi)) (x,y) = let
    res = x >= xlo && x <= xhi && y >= ylo && y <= yhi
    in trace ("in bbox: "++ show res) res

--TODO: offset
isInB' :: Autofloat a => Blob a -> Pt2 a -> Bool
isInB' pts (x0, y0) = let
    bbox = getBBox pts
    in if not $ inBBox bbox (x0,y0) then False else
    isInB pts (x0,y0)

scaleB :: Autofloat a => a -> Blob a -> Blob a
scaleB k b = map (scaleP k) b

circumfrenceB :: Autofloat a => Blob a -> a
circumfrenceB blob = foldl' (+) 0.0 $ map (\(a,b)->dist a b) $ getSegmentsB blob

-- sample points along segment with interval.
sampleS :: Autofloat a => a -> LineSeg a -> [Pt2 a]
sampleS numSamplesf (a, b) = let
    -- l = mag $ b -: a
    numSamples = (floor numSamplesf) + 1--floor $ l/interval
    inds = map realToFrac [0..numSamples-1]
    ks = map (/(realToFrac numSamples)) $ inds
    in map (lerpP a b) ks

sampleB :: Autofloat a => Int -> Blob a -> [Pt2 a]
sampleB numSamples blob = let
    numSamplesf = r2f numSamples
    segments = getSegmentsB blob
    circumfrence = foldl' (+) 0.0 $ map (\(a,b)->dist a b) segments
    seglengths = map (\(a,b)->dist a b) $ segments
    samplesEach = map (\l->l/circumfrence*numSamplesf) seglengths
    zp = zip segments samplesEach
    in concat $ map (\(seg, num) -> sampleS num seg) zp

-- TODO: be absolutely sure #samples are same as input #
sampleG :: Autofloat a => Int -> Polygon a -> [Pt2 a]
sampleG numSamples (bds, hs) = let 
    numSamplesf = r2f numSamples
    segments = getSegmentsG (bds, hs)
    circumfrence = foldl' (+) 0.0 $ map (\(a,b)->dist a b) segments
    seglengths = map (\(a,b)->dist a b) $ segments
    samplesEach = map (\l->l/circumfrence*numSamplesf) seglengths
    zp = zip segments samplesEach
    in concat $ map (\(seg, num) -> sampleS num seg) zp

---- dsq functions ----

-- ofs: "offset". ofs = k means dsqPP returns 0 when a and b are at most k units apart
-- might need some sanity check for correctness
dsqPP :: Autofloat a => Pt2 a -> Pt2 a -> a -> a
dsqPP a b ofs = max 0 $ (magsq $ b -: a) - (ofs**2)

dsqSP :: Autofloat a => LineSeg a -> Pt2 a -> a -> a
dsqSP (a,b) p ofs = let t = gettPS p (a,b) in
    if t<0 then dsqPP a p ofs
    else if t>1 then dsqPP b p ofs
    else max 0 $ ( (**2) $ (normS (a,b)) `dotv` (p -: a) ) - (ofs**2)

dsqSS :: Autofloat a => LineSeg a -> LineSeg a -> a -> a
dsqSS (a,b) (c,d) ofs = if ixSS (a,b) (c,d) then 0 else let
    da = dsqSP (c,d) a ofs
    db = dsqSP (c,d) b ofs
    dc = dsqSP (a,b) c ofs
    dd = dsqSP (a,b) d ofs
    in min (min da db) (min dc dd)

dsqBP :: Autofloat a => Blob a -> Pt2 a -> a -> a
dsqBP b p ofs = let
    segments = getSegmentsB b
    d2segments = map (\s -> dsqSP s p ofs) segments
    in foldl' min posInf d2segments

dsqGP :: Autofloat a => Polygon a -> Pt2 a -> a -> a
dsqGP (bds, hs) p ofs = let
    dsqBD = foldl' min posInf $ map (\b -> dsqBP b p ofs) bds
    dsqHS = foldl' min posInf $ map (\h -> dsqBP h p ofs) hs
    in min dsqBD dsqHS

dsqBS :: Autofloat a => Blob a -> LineSeg a -> a -> a
dsqBS b s ofs = foldl' min posInf $ 
    map (\e -> dsqSS e s ofs) $ getSegmentsB b

-- this is itself an energy (for boundary intersection)
dsqBB :: Autofloat a => Blob a -> Blob a -> a -> a
dsqBB b1 b2 ofs = let
    min1 = foldl' min posInf $ map (\e -> dsqBS b2 e ofs) $ getSegmentsB b1
    in min1

dsqGG :: Autofloat a => Polygon a -> Polygon a -> a -> a
dsqGG (bds1, hs1) (bds2, hs2) ofs = let
    b1b2 = foldl' min posInf $ map (\b->foldl' min posInf $ map (\b'->dsqBB b b' ofs) bds1) bds2
    b1h2 = foldl' min posInf $ map (\b->foldl' min posInf $ map (\b'->dsqBB b b' ofs) bds1) hs2
    b2b1 = foldl' min posInf $ map (\b->foldl' min posInf $ map (\b'->dsqBB b b' ofs) bds2) bds1
    b2h1 = foldl' min posInf $ map (\b->foldl' min posInf $ map (\b'->dsqBB b b' ofs) bds2) hs1
    in min (min b1b2 b1h2) (min b2b1 b2h1)

---- dsq integral along boundary functions ----

-- actually means "#samples per polygon"
ds :: Int
ds = 200

-- scalefactor :: Autofloat a => a
-- scalefactor = 1 -- doesn't behave as expected though?

dsqBinA :: Autofloat a => Polygon a -> Polygon a -> a -> a
dsqBinA bA bB ofs = let
    -- circumfrence = foldl' (+) 0.0 $ map (\(a,b)->dist a b) $ getSegmentsB bB
    -- interval = (r2f ds) / circumfrence
    samplesIn = filter (\p -> isInG bA p) $ sampleG ds bB
    res = {-(*interval) $-} foldl' (+) 0.0 $ map (\p -> dsqGP bA p ofs) samplesIn
    in {-trace ("|samplesIn|: " ++ show (length samplesIn))-} res

dsqBoutA :: Autofloat a => Polygon a -> Polygon a -> a -> a
dsqBoutA bA bB ofs = let
    -- circumfrence = foldl' (+) 0.0 $ map (\(a,b)->dist a b) $ getSegmentsB bB
    -- interval = (r2f ds) / circumfrence
    samplesOut = filter (\p -> not $ isInG bA p) $ sampleG ds bB
    res = {-(*interval) $-} foldl' (+) 0.0 $ map (\p -> dsqGP bA p ofs) samplesOut
    in {-trace ("|samplesOut|: " ++ show (length samplesOut))-} res

---- query energies ----

-- containment
-- TODO: when two shapes start disjoint, #samples = 0???
eAcontainB :: Autofloat a => Polygon a -> Polygon a -> a -> a
eAcontainB bA bB ofs = let
    eAinB = dsqBinA bB bA ofs
    eBoutA = dsqBoutA bA bB ofs
    in eAinB + eBoutA

-- disjoint. might be changed later though, bc it gets stuck at local min too often,
-- resulting in two shapes overlap even more
eABdisj :: Autofloat a => Polygon a -> Polygon a -> a -> a
eABdisj bA bB ofs = let
    eAinB = dsqBinA bB bA ofs
    eBinA = dsqBinA bA bB ofs
    in eAinB + eBinA

-- A and B tangent, B inside A
eBinAtangent :: Autofloat a => Polygon a -> Polygon a -> a -> a
eBinAtangent bA bB ofs = let
    eContainment = eAcontainB bA bB ofs
    eABbdix = dsqGG bA bB ofs
    in eContainment + eABbdix

-- A and B tangent, B outside A
eBoutAtangent :: Autofloat a => Polygon a -> Polygon a -> a -> a
eBoutAtangent bA bB ofs = let
    eDisjoint = eABdisj bA bB ofs
    eABbdix = dsqGG bA bB ofs
    in eDisjoint + eABbdix