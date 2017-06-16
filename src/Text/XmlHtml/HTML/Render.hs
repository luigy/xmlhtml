{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}

module Text.XmlHtml.HTML.Render where

-- import           Blaze.ByteString.Builder
import           Data.Char
import           Data.Text.Internal.Builder hiding (fromText)
import qualified Data.Text.Internal.Builder as TB
import           Control.Applicative
import           Data.Maybe
import qualified Text.Parsec as P
import           Text.XmlHtml.Common hiding (fromText)
import           Text.XmlHtml.TextParser
import           Text.XmlHtml.HTML.Meta
import qualified Text.XmlHtml.HTML.Parse as P
-- import           Text.XmlHtml.XML.Render (docTypeDecl, entity)

import           Data.Text (Text)
import qualified Data.Text as T

import qualified Data.HashSet as S
import qualified Data.HashMap.Strict as M

#if !MIN_VERSION_base(4,8,0)
import           Data.Monoid
#endif

fromText :: a -> Text -> Builder
fromText _ = TB.fromText

------------------------------------------------------------------------------
-- | And, the rendering code.
render :: Encoding -> Maybe DocType -> [Node] -> Builder
render e dt ns = byteOrder
       `mappend` docTypeDecl e dt
       `mappend` nodes
    where byteOrder | isUTF16 e = fromText e "\xFEFF" -- byte order mark
                    | otherwise = mempty
          nodes | null ns   = mempty
                | otherwise = firstNode e (head ns)
                    `mappend` (mconcat $ map (node e) (tail ns))


------------------------------------------------------------------------------
-- | Function for rendering HTML nodes without the overhead of creating a
-- Document structure.
renderHtmlFragment :: Encoding -> [Node] -> Builder
renderHtmlFragment _ []     = mempty
renderHtmlFragment e (n:ns) =
    firstNode e n `mappend` (mconcat $ map (node e) ns)


------------------------------------------------------------------------------
-- | HTML allows & so long as it is not "ambiguous" (i.e., looks like an
-- entity).  So we have a special case for that.
escaped :: [Char] -> Encoding -> Text -> Builder
escaped _   _ "" = mempty
escaped bad e t  =
    let (p,s) = T.break (`elem` bad) t
        r     = T.uncons s
    in  fromText e p `mappend` case r of
            Nothing
                -> mempty
            Just ('&',ss) | isLeft (parseText ambigAmp "" s)
                -> fromText e "&" `mappend` escaped bad e ss
            Just (c,ss)
                -> entity e c `mappend` escaped bad e ss
  where isLeft   = either (const True) (const False)
        ambigAmp = P.char '&' *>
            (P.finishCharRef *> return () <|> P.finishEntityRef *> return ())


------------------------------------------------------------------------------
node :: Encoding -> Node -> Builder
node e (TextNode t)                        = escaped "<>&" e t
node e (Comment t) | "--" `T.isInfixOf`  t = error "Invalid comment"
                   | "-"  `T.isSuffixOf` t = error "Invalid comment"
                   | otherwise             = fromText e "<!--"
                                             `mappend` fromText e t
                                             `mappend` fromText e "-->"
node e (Element t a c)                     =
    let tbase = T.toLower $ snd $ T.breakOnEnd ":" t
    in  element e t tbase a c


------------------------------------------------------------------------------
-- | Process the first node differently to encode leading whitespace.  This
-- lets us be sure that @parseHTML@ is a left inverse to @render@.
firstNode :: Encoding -> Node -> Builder
firstNode e (Comment t)     = node e (Comment t)
firstNode e (Element t a c) = node e (Element t a c)
firstNode _ (TextNode "")   = mempty
firstNode e (TextNode t)    = let (c,t') = fromJust $ T.uncons t
                              in escaped "<>& \t\r" e (T.singleton c)
                                 `mappend` node e (TextNode t')


------------------------------------------------------------------------------
-- XXX: Should do something to avoid concatting large CDATA sections before
-- writing them to the output.
element :: Encoding -> Text -> Text -> [(Text, Text)] -> [Node] -> Builder
element e t tb a c
    | tb `S.member` voidTags && null c         =
        fromText e "<"
        `mappend` fromText e t
        `mappend` (mconcat $ map (attribute e tb) a)
        `mappend` fromText e " />"
    | tb `S.member` voidTags                   =
        error $ T.unpack t ++ " must be empty"
    | isRawText tb a,
      all isTextNode c,
      let s = T.concat (map nodeText c),
      not ("</" `T.append` t `T.isInfixOf` s) =
        fromText e "<"
        `mappend` fromText e t
        `mappend` (mconcat $ map (attribute e tb) a)
        `mappend` fromText e ">"
        `mappend` fromText e s
        `mappend` fromText e "</"
        `mappend` fromText e t
        `mappend` fromText e ">"
    | isRawText tb a,
      [ TextNode _ ] <- c                     =
        error $ T.unpack t ++ " cannot contain text looking like its end tag"
    | isRawText tb a                           =
        error $ T.unpack t ++ " cannot contain child elements or comments"
    | otherwise =
        fromText e "<"
        `mappend` fromText e t
        `mappend` (mconcat $ map (attribute e tb) a)
        `mappend` fromText e ">"
        `mappend` (mconcat $ map (node e) c)
        `mappend` fromText e "</"
        `mappend` fromText e t
        `mappend` fromText e ">"


------------------------------------------------------------------------------
attribute :: Encoding -> Text -> (Text, Text) -> Builder
attribute e tb (n,v)
    | v == "" && not explicit               =
        fromText e " "
        `mappend` fromText e n
    | v /= "" && not ("\'" `T.isInfixOf` v) =
        fromText e " "
        `mappend` fromText e n
        `mappend` fromText e "=\'"
        `mappend` escaped "&" e v
        `mappend` fromText e "\'"
    | otherwise                             =
        fromText e " "
        `mappend` fromText e n
        `mappend` fromText e "=\""
        `mappend` escaped "&\"" e v
        `mappend` fromText e "\""
  where nbase    = T.toLower $ snd $ T.breakOnEnd ":" n
        explicit = case M.lookup tb explicitAttributes of
                     Nothing -> False
                     Just ns -> nbase `S.member` ns

entity :: Encoding -> Char -> Builder
entity e '&'  = fromText e "&amp;"
entity e '<'  = fromText e "&lt;"
entity e '>'  = fromText e "&gt;"
entity e '\"' = fromText e "&quot;"
entity e c    = fromText e "&#"
                `mappend` fromText e (T.pack (show (ord c)))
                `mappend` fromText e ";"

docTypeDecl :: Encoding -> Maybe DocType -> Builder
docTypeDecl _ Nothing                      = mempty
docTypeDecl e (Just (DocType tag ext int)) = fromText e "<!DOCTYPE "
                                   `mappend` fromText e tag
                                   `mappend` externalID e ext
                                   `mappend` internalSubset e int
                                   `mappend` fromText e ">\n"

externalID :: Encoding -> ExternalID -> Builder
externalID _ NoExternalID     = mempty
externalID e (System sid)     = fromText e " SYSTEM "
                                `mappend` sysID e sid
externalID e (Public pid sid) = fromText e " PUBLIC "
                                `mappend` pubID e pid
                                `mappend` fromText e " "
                                `mappend` sysID e sid

sysID :: Encoding -> Text -> Builder
sysID e sid | not ("\'" `T.isInfixOf` sid) = fromText e "\'"
                                             `mappend` fromText e sid
                                             `mappend` fromText e "\'"
            | not ("\"" `T.isInfixOf` sid) = fromText e "\""
                                             `mappend` fromText e sid
                                             `mappend` fromText e "\""
            | otherwise               = error "SYSTEM id is invalid"

internalSubset :: Encoding -> InternalSubset -> Builder
internalSubset _ NoInternalSubset = mempty
internalSubset e (InternalText t) = fromText e " " `mappend` fromText e t

pubID :: Encoding -> Text -> Builder
pubID e sid | not ("\"" `T.isInfixOf` sid) = fromText e "\""
                                             `mappend` fromText e sid
                                             `mappend` fromText e "\""
            | otherwise               = error "PUBLIC id is invalid"
