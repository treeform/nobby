import
  std/strutils,
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
  isAdmin = false
): string =
  ## Renders page shell and shared navigation.
  let breadcrumbHtml = renderBreadcrumb(breadcrumb)
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
                  a:
                    href "/logout"
                    say "Logout"
          if breadcrumb.len > 0:
            say breadcrumbHtml
          say content
          p ".footer-note":
            say AppFooter
