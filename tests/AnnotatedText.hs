{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}

import Test.HUnit
import Text.MediaWiki.AnnotatedText
import WikiPrelude
import Control.Monad

linkTest = makeLink "" "test" "" "test"
linkExample = makeLink "en" "example" "#English" "example"
at1 = annotate [linkTest] "test"
at2 = annotate [linkExample] "example"

-- define a third AnnotatedText as a string literal
atLiteral :: AnnotatedText
atLiteral = "literal"

tests = test [
    "getText" ~: getText at1 ~?= "test",
    "getText empty" ~: getText mempty ~?= "",
    "getAnnotations" ~: getAnnotations at1 ~?= [linkTest],
    "getAnnotations empty" ~: getAnnotations mempty ~?= [],
    "getAnnotations literal" ~: getAnnotations atLiteral ~?= [],

    ("concat 0" ~:
      let a :: [AnnotatedText]
          a = []
      in concat a ~?= mempty
    ),
    "concat 1" ~: concat [at1] ~?= at1,
    "concat 2" ~: concat [at1, at2] ~?= annotate [linkTest, linkExample] "testexample",

    "joinAnnotatedLines 0" ~: joinAnnotatedLines [] ~?= mempty,
    "joinAnnotatedLines 1" ~: joinAnnotatedLines [at1] ~?= at1 ++ annotFromText "\n",
    "joinAnnotatedLines 2" ~: joinAnnotatedLines [at1, at2] ~?= annotate [linkTest, linkExample] "test\nexample\n",

    "transformA" ~: transformA toUpper at2 ~?= annotate [linkExample] "EXAMPLE"
    ]

main :: IO ()
main = void (runTestTT tests)
