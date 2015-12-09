\section{Setup}

To parse the mess that is Wiktionary, we make use of Parsec, perhaps the
best-regarded parser-combinator library I've ever encountered.

Parsec is explicitly designed around the way Haskell works. I wouldn't
normally be using Haskell, but it does seem like the right tool for the job.

> module Text.Wiki.MediaWiki where
> import Text.Parsec hiding (parse, parseTest)
> import Text.Parsec.Char
> import Control.Monad.Identity

We're going to need to make use of Haskell's functional mapping type,
Data.Map, to represent the contents of templates.

> import Data.Map (Map)
> import qualified Data.Map as Map

Pull in some string-manipulating utilities that are defined elsewhere in
this package:

> import Text.SplitUtils

And some more utilities from the MissingH package:

> import Data.String.Utils


\section{Data types}

An internal link is represented as a record of a type we'll define here,
called ``WikiLink''.

> data WikiLink = WikiLink {
>   namespace :: String,
>   page :: String,
>   section :: String
> } deriving (Show, Eq)

An invocation of a template is represented as a Map from parameter names to
values.  Both the names and the values are strings.

> type TemplateData = Map String String

We'll also define a type expression called Parser. The type expression Parsec
takes three arguments: the input type, the state type, and the output type.

For most expressions in this file, the input type will be String and the state
type will be LinkState, a short-lived state that keeps track of links that have
appeared in the text. All we have left to specify is the output type, which can
vary, so we won't fill in that argument.

> type Parser = Parsec String LinkState

The definition of LinkState will be straightforward -- it's just a list of
WikiLinks -- but let's save defining it for later, because we're also going to
define some functions for working with it.


\section{Parser-making expressions}

The awkward thing about LL parsing is that you can consume part of a string,
fail to match the rest of it, and be unable to backtrack. When we match a
string, we usually want it to be an all-or-nothing thing. At the cost of a bit
of efficiency, we'll use the {\tt symbol} expression for multi-character
strings, which wraps the {\tt string} combinator in {\tt try} so it can
backtrack.

> symbol = try . string

This is similar to the {\tt symbol} that's defined in Parsec's token-based
parse rules, but we're not importing those because they don't coexist with
significant whitespace.

In various situations, we'll want to parse ``some amount of arbitrary text
without syntax in it''. But what this means is, unfortunately, different in
different situations. Sometimes line breaks are allowed. Sometimes unmatched
brackets and braces are allowed. And so on.

To make this easier, we'll define {\tt textChoices}, which takes a list of
expressions we're allowed to parse, tries all of them in that priority order,
and concatenates together their results.

> textChoices :: [Parser String] -> Parser String
> textChoices options = concatMany (choice (map try options))
>
> concatMany :: Parser String -> Parser String
> concatMany combinator = do
>   parts <- many combinator
>   return (concat parts)

\subsection{The ``and-then'' operator}

I'm going to define a new operator that's going to be pretty useful in a lot of
these expressions. Often I have a function that's in some monad, like {\tt
Parser String}, and I want to apply a transformation to its output, like {\tt
String -> String}.

The {\tt liftM} function almost does this: it converts {\tt String -> String}
to {\tt Parser String -> Parser String}, for example. But it's just a function,
and you apply functions on the left... so the last thing you do has to be the
first thing you write. This is confusing because the rest of the parser
expression is usually written in sequential order, especially when it's using
{\tt do} syntax.

So this operator, the ``and-then'' operator, lets me write the thing that needs
to happen to the output at the end. I could just define it as (flip liftM), but
that would be pointless. (Functional programming puns! Hooray!)

> (&>) :: Monad m => m a -> (a -> b) -> m b
> (&>) result f = liftM f result

\section{Spans of text}

I forget exactly why, but I think we're going to need an expression that
allows whitespace as long as it stays on the same line. (FIXME check this)
If we allowed linebreaks, we could just use {\tt spaces} from
Text.Parsec.Char.

Wikitext is whitespace-sensitive. (FIXME describe more)

> sameLineSpaces :: Parser ()
> sameLineSpaces = skipMany (oneOf " \t")

The ``ignored'' expression matches HTML tags and comments and throws them
away.

> ignored :: Parser String
> ignored = do
>   skipMany1 ignoredItem
>   return ""
>
> ignoredItem = try htmlComment <|> try htmlTag
>
> htmlComment :: Parser String
> htmlComment = do
>   string "<!--"
>   manyTill anyChar (symbol "-->")
>
> htmlTag :: Parser String
> htmlTag = do
>   char '<'
>   manyTill anyChar (char '>')

Our most reusable expression for miscellaneous text, {\tt basicText}, matches
characters that aren't involved in any interesting Wiki syntax.

But wait, what about the *uninteresting* Wiki syntax? Any span of Wikitext can
have double or triple apostrophes in it to indicate bold and italic text.
Single apostrophes are, of course, just apostrophes.

We could modify every parse rule that handles basic text to also have a case
for bold and italic spans and an exception for individual apostrophes, but
instead, we could take advantage of the fact that these spans are at the lowest
level of syntax and we want to ignore them anyway.

We'll just post-process the parse result to remove the sequences of
apostrophes, by chaining it through the {\tt discardSpans} function.

> basicText :: Parser String
> basicText = many1 (noneOf "[]{}|<>:=\n") &> discardSpans
>
> discardSpans :: String -> String
> discardSpans = (replace "''" "") . (replace "'''" "")

There's a quirk in Wiki syntax: things that would cause syntax errors just get
output as themselves. So sometimes, some of the characters excluded by {\tt
basicText} are going to appear as plain text, even in contexts where they would
have a meaning -- such as a single closing bracket when two closing brackets
would end a link.

It would be excessive to actually try to simulate MediaWiki's error handling,
but we can write this expression that allows ``loose brackets'' to be matched
as text:

> looseBracket :: Parser String
> looseBracket = do
>   notFollowedBy internalLink
>   notFollowedBy externalLink
>   notFollowedBy template
>   bracket <- oneOf "[]{}"
>   notFollowedBy (char bracket)
>   return [bracket]

Wikitext in general is made of HTML, links, templates, and miscellaneous text.
We'll parse templates for their meaning below, but in situations where we don't
care about templates, we simply discard their contents using the {\tt
ignoredTemplate} rule.

> wikiTextLine :: Parser String
> wikiTextLine = textChoices [ignored, internalLink, externalLink, ignoredTemplate, looseBracket, textLine]
> wikiText = textChoices [ignored, internalLink, externalLink, ignoredTemplate, looseBracket, textLine, newLine]
> textLine = many1 (noneOf "[]{}<>\n") &> discardSpans
> newLine = string "\n"

> eol :: Parser ()
> eol = (newLine >> return ()) <|> eof


\section{Wiki syntax items}

\subsection{Links}

External links appear in single brackets. They contain a URL, a space, and
the text that labels the link, such as:

\begin{verbatim}
In:  [http://www.americanscientist.org/authors/detail/david-van-tassel David Van Tassel]
Out: "David Van Tassel"
\end{verbatim}

External links can have no text, in which case they just get an arbitrary
number as their text, which we'll disregard. There's also a type of external
link that is just a bare URL in the text. Its effect on the text is exactly
the same as if it weren't a link, so we can disregard that case.

The following rules extract the text of an external link, as both ``between''
and ``do'' return their last argument.

> externalLink :: Parser String
> externalLink = between (string "[") (string "]") externalLinkContents
> externalLinkContents = do
>   schema
>   urlPath
>   spaces
>   linkTitle
> schema = choice (map string ["http://", "https://", "ftp://", "news://", "irc://", "mailto:", "//"])
> urlPath = many1 (noneOf "[]{}<>| ")
> linkTitle = textChoices [ignored, linkText]
> linkText = many1 (noneOf "[]{}|<>") &> discardSpans

Internal links have many possible components. In general, they take the form:

>--   [[namespace:page#section|label]]

The only part that has to be present is the page name. If the label is not
given, then the label is the same as the page.

When parsing internal links, we return just their label. However, other
details of the link are added to the LinkState.

\begin{verbatim}

     In: [[word]]
    Out: "word"
  State: [makeLink {page="word"}]

     In: [[word|this word]]
    Out: "this word"
  State: [makeLink {page="word"}]

     In: [[word#English]]
    Out: "word"
  State: [makeLink {page="word", section="English"}]

     In: [[w:en:Word]]
    Out: "word"
  State: [makeLink {namespace="w:en", page="word"}]

     In: [[Category:English nouns]]
    Out: ""
  State: [makeLink {namespace="Category", page="English nouns"}]

\end{verbatim}

> internalLink :: Parser String
> internalLink = between (symbol "[[") (symbol "]]") internalLinkContents
> internalLinkContents = do
>   target <- linkTarget
>   maybeText <- optionMaybe alternateText
>   let link = (parseLink target) in do
>     updateState (addLink link)
>     case (namespace link) of
>       -- Certain namespaces have special links that make their text disappear
>       "Image"    -> return ""
>       "Category" -> return ""
>       "File"     -> return ""
>       -- If the text didn't disappear, find the text that labels the link
>       _          -> case maybeText of
>         Just text  -> return text
>         Nothing    -> return (page link)
>
> linkTarget :: Parser String
> linkTarget = many1 (noneOf "[]{}|<>\n")
>
> alternateText = string "|" >> linkText
>
> parseLink :: String -> WikiLink
> parseLink target =
>   WikiLink {namespace=namespace, page=page, section=section}
>   where
>     (namespace, local) = splitLast ':' target
>     (page, section) = splitFirst '#' local

\subsection{Headings}

When parsing an entire Wiki article, you'll need to identify where the
headings are. This is especially true on Wiktionary, where the
domain-specific parsing rules will change based on the heading.

The {\tt heading} parser looks for a heading of a particular level (for
example, a level-2 heading is one delimited by {\tt ==}), and returns its
title.

> heading :: Int -> Parser String
> heading level =
>   let delimiter = (replicate level '=') in do
>     symbol delimiter
>     optional sameLineSpaces
>     text <- headingText
>     optional sameLineSpaces
>     symbol delimiter
>     optional sameLineSpaces
>     newLine
>     return text
>
> headingText = textChoices [ignored, internalLink, externalLink, ignoredTemplate, looseBracket, basicText]

\subsection{Lists}

> data ListItem = Item String
>               | ListHeading String
>               | BulletList [ListItem]
>               | OrderedList [ListItem]
>               | IndentedList [ListItem]
>               deriving (Show, Eq)
>
> listItems :: String -> Parser [ListItem]
> listItems marker = do
>   lookAhead (string marker)
>   many1 (listItem marker)
>
> listItem :: String -> Parser ListItem
> listItem marker = subList marker <|> singleListItem marker
> 
> subList :: String -> Parser ListItem
> subList marker =   try (bulletList (marker ++ "*"))
>                <|> try (orderedList (marker ++ "#"))
>                <|> try (indentedList (marker ++ ":"))
>                <|> try (listHeading (marker ++ ";"))
>
> anyList :: Parser ListItem
> anyList = subList ""
>
> listHeading :: String -> Parser ListItem
> listHeading marker = listItemContent marker &> ListHeading
>
> singleListItem :: String -> Parser ListItem
> singleListItem marker = listItemContent marker &> Item
>
> listItemContent :: String -> Parser String
> listItemContent marker = do
>   symbol marker
>   optional sameLineSpaces
>   line <- wikiTextLine
>   eol
>   return line
>
> bulletList marker   = listItems marker &> BulletList
> orderedList marker  = listItems marker &> OrderedList
> indentedList marker = listItems marker &> IndentedList

\subsection{Templates}

A simple template looks like this:

>--   {{archaic}}

More complex templates take arguments, such as this translation into French:

>--   {{t+|fr|exemple|m}}

And very complex templates can have both positional and named arguments:

>--   {{t|ja|例え|tr=[[たとえ]], tatoe}}

Some templates are more detailed versions of internal links. Some are metadata
that we can simply ignore. The ultimate semantics of a template can depend both
on its contents and the section in which it appears, so these semantics need to
be defined in the parsing rules for a specific wiki such as the English
Wiktionary.

Here, we define the basic syntax of templates, and return their contents in a
standardized form as a mapping from argument names to values.

> template :: Parser TemplateData
> template = symbol "{{" >> (templateArgs 0)
>
> ignoredTemplate :: Parser String
> ignoredTemplate = template >> return ""

> templateArgs :: Int -> Parser TemplateData
> templateArgs offset = do
>   nameMaybe <- optionMaybe (try templateArgName)
>   case nameMaybe of
>     Just name -> namedArg name offset
>     Nothing -> positionalArg offset
>
> templateArgName :: Parser String
> templateArgName = do
>   name <- basicText
>   string "="
>   return name
>
> namedArg :: String -> Int -> Parser TemplateData
> namedArg name offset = do
>   value <- wikiTextArg
>   rest <- templateRest offset
>   return (Map.insert name value rest)
>
> positionalArg :: Int -> Parser TemplateData
> positionalArg offset = do
>   value <- wikiTextArg
>   rest <- templateRest (offset + 1)
>   return (Map.insert (show offset) value rest)
>
> templateRest :: Int -> Parser TemplateData
> templateRest offset = endOfTemplate <|> (string "|" >> templateArgs offset)
>
> endOfTemplate = symbol "}}" >> return Map.empty
>
> wikiTextArg = textChoices [ignored, internalLink, externalLink, looseBracket, textArg]
> textArg = many1 (noneOf "[]{}<>|") &> discardSpans

We can simplify some of this parsing in the case where we are looking for a
{\em particular} template.

> knownTemplate :: String -> Parser TemplateData
> knownTemplate name = do
>   symbol ("{{" ++ name)
>   parsed <- templateArgs 1
>   return (Map.insert "0" name parsed)

\section{Keeping track of state}

As our parser runs, it will be collecting links in a value that we call a
LinkState.

> type LinkState = [WikiLink]

The {\tt makeLink} constructor allows creating a WikiLink where the
values default to the empty string.

> makeLink = WikiLink {namespace="", page="", section=""}

Here are some functions that apply to LinkStates:

> newState :: LinkState
> newState = []
>
> resetState :: LinkState -> LinkState
> resetState ps = []
>
> addLink :: WikiLink -> LinkState -> LinkState
> addLink = (:)

And here's a variant of the wikiText parser combinator that returns the list
of WikiLinks that it accumulates:

> wikiTextLinks :: Parser LinkState
> wikiTextLinks = do
>   text <- wikiText
>   getState


\section{Entry points}

Parsec defines useful helpers such as parseTest, but they require the parser
to have no modifiable state. We care a lot about the modifiable state, so
we'll write our own version.

> parseTest parser input =
>   let sourceName = "(test)" in
>     case parse parser sourceName input of
>       Left err -> do
>         putStr "parse error at "
>         print err
>       Right x -> do
>         print x
>
> parse parser = runParser parser newState
