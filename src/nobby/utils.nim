import
  std/strutils,
  markdown,
  taggy

const
  AppTitle* = "Nobby, a bulletin board style forum"
  AppTagline* = "Visual forum inspired by the early 2000s message boards."
  AppFooter* = "Copyright 2026 Nobby. MIT License."

proc esc*(text: string): string =
  ## Escapes HTML special characters.
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc truncateUtf8*(s: string, maxBytes: int): string =
  ## Truncates to at most maxBytes without splitting a UTF-8 rune.
  if maxBytes <= 0:
    return ""
  if s.len <= maxBytes:
    return s
  var endAt = maxBytes
  while endAt > 0 and (ord(s[endAt]) and 0xC0) == 0x80:
    dec endAt
  s[0 ..< endAt]

proc normalizeMarkdownUrl(url: string): string =
  ## Lowercases and strips whitespace used to hide schemes.
  for c in url.toLowerAscii():
    if c notin {'\t', '\n', '\r', ' ', '\0'}:
      result.add(c)
  result = result.replace("&colon;", ":")
  result = result.replace("&#58;", ":")
  result = result.replace("&#x3a;", ":")

proc isSafeMarkdownHref*(url: string): bool =
  ## Returns true for http, https, mailto, or relative URLs.
  let cleaned = normalizeMarkdownUrl(url)
  if cleaned.len == 0:
    return true
  if cleaned.startsWith("http://") or
    cleaned.startsWith("https://") or
    cleaned.startsWith("mailto:") or
    cleaned.startsWith("//"):
    return true
  let schemeEnd = cleaned.find(':')
  if schemeEnd < 0:
    return true
  let pathish = cleaned.find({'/', '?', '#'})
  pathish >= 0 and pathish < schemeEnd

proc isSafeMarkdownSrc*(url: string): bool =
  ## Returns true for http, https, or relative image URLs.
  let cleaned = normalizeMarkdownUrl(url)
  if cleaned.len == 0:
    return true
  if cleaned.startsWith("http://") or
    cleaned.startsWith("https://") or
    cleaned.startsWith("//"):
    return true
  let schemeEnd = cleaned.find(':')
  if schemeEnd < 0:
    return true
  let pathish = cleaned.find({'/', '?', '#'})
  pathish >= 0 and pathish < schemeEnd

proc replaceUnsafeAttrUrls(html: string, attr: string, allowMailto: bool): string =
  ## Rewrites one quoted HTML attribute to drop unsafe URLs.
  let needle = attr & "=\""
  var i = 0
  while true:
    let startAt = html.find(needle, i)
    if startAt < 0:
      result.add(html[i .. ^1])
      break
    result.add(html[i ..< startAt])
    let valueStart = startAt + needle.len
    let valueEnd = html.find('"', valueStart)
    if valueEnd < 0:
      result.add(html[startAt .. ^1])
      break
    let url = html[valueStart ..< valueEnd]
    result.add(needle)
    let safe =
      if allowMailto:
        isSafeMarkdownHref(url)
      else:
        isSafeMarkdownSrc(url)
    if safe:
      result.add(url)
    else:
      result.add("#")
    result.add('"')
    i = valueEnd + 1

proc sanitizeMarkdownHtml*(html: string): string =
  ## Neutralizes javascript and other unsafe URL schemes in HTML.
  result = replaceUnsafeAttrUrls(html, "href", true)
  result = replaceUnsafeAttrUrls(result, "src", false)

proc renderSafeMarkdown*(text: string): string =
  ## Renders GFM markdown with HTML escaped and unsafe URLs removed.
  sanitizeMarkdownHtml(
    markdown(
      text,
      config = initGfmConfig(
        escape = true,
        keepHtml = false
      )
    )
  )

proc renderCsrfField*(csrfToken: string): string =
  ## Renders a hidden CSRF input for POST forms.
  renderFragment:
    input:
      ttype "hidden"
      name "csrf"
      value esc(csrfToken)

proc renderPagination*(basePath: string, page: int, pages: int): string =
  ## Renders compact pagination links.
  renderFragment:
    tdiv ".pagination":
      p ".smalltext":
        span ".label":
          say "Page"
        strong:
          say $page
        say " of "
        strong:
          say $pages
        if pages > 1:
          say " | Go to "
          for i in 1 .. pages:
            if i == page:
              strong:
                say $i
            else:
              a:
                href basePath & "?page=" & $i
                say $i

proc renderBreadcrumb*(pathItems: seq[(string, string)]): string =
  ## Renders breadcrumb links for page navigation.
  renderFragment:
    p ".smalltext":
      span ".crumb smalltext":
        for i, (title, hrefValue) in pathItems:
          if hrefValue.len > 0:
            a:
              href hrefValue
              say esc(title)
          else:
            say esc(title)
          if i < pathItems.high:
            say " > "

proc renderLayout*(
  pageTitle: string,
  content: string,
  currentUsername = "",
  breadcrumb: seq[(string, string)] = @[],
  isAdmin = false,
  csrfToken = ""
): string =
  ## Renders page shell and shared navigation.
  let
    breadcrumbHtml = renderBreadcrumb(breadcrumb)
    csrfField = renderCsrfField(csrfToken)
  render:
    html:
      head:
        title:
          say esc(pageTitle) & " - Nobby"
        link:
          rel "stylesheet"
          href "/style.css"
      body:
        tdiv ".page":
          table ".lineup header-layout":
            tr:
              td ".smalltext":
                p ".smalltext":
                  span ".maintitle":
                    say AppTitle
                p ".smalltext":
                  say AppTagline
              td ".right.smalltext account-cell":
                if currentUsername.len == 0:
                  a:
                    href "/login"
                    say "Login"
                  say " | "
                  a:
                    href "/register"
                    say "Register"
                else:
                  say "User: "
                  b:
                    a ".topiclink":
                      href "/u/" & currentUsername
                      say esc(currentUsername)
                  say " | "
                  form ".inline-form":
                    action "/logout"
                    tmethod "post"
                    say csrfField
                    button ".linkish":
                      ttype "submit"
                      say "Logout"
          if breadcrumb.len > 0:
            say breadcrumbHtml
          say content
          p ".footer-note":
            say AppFooter
