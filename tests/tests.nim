import
  std/[os, osproc, streams, strutils, times],
  debby/[pools, sqlite],
  webby,
  curly

const
  BaseUrl = "http://localhost:8080"

proc waitForServer(client: Curly, server: Process, timeoutMs = 15000) =
  ## Waits until the local forum server responds.
  let started = epochTime()
  while true:
    let code = server.peekExitCode()
    if code != -1:
      let output = server.outputStream.readAll()
      doAssert false, "Server exited early with code " & $code & ". Output:\n" & output
    try:
      discard client.get(BaseUrl & "/")
      return
    except:
      if int((epochTime() - started) * 1000) > timeoutMs:
        doAssert false, "Server did not start on http://localhost:8080 in time."
      sleep(150)

proc ensurePortIsFree(client: Curly) =
  ## Ensures no process already serves on port 8080.
  try:
    discard client.get(BaseUrl & "/")
    doAssert false, "Port 8080 is already in use. Stop running nobby server before tests."
  except:
    discard

proc stopExistingServer(client: Curly) =
  ## Attempts to stop a server already running on localhost:8080.
  try:
    discard client.get(BaseUrl & "/quit")
  except:
    discard
  sleep(400)

proc compileServer(repoRoot: string, outPath: string) =
  ## Compiles the nobby server executable to the provided output path.
  let command = "nim c --out:" & quoteShell(outPath) & " " &
    quoteShell(repoRoot / "src" / "nobby.nim")
  let build = execCmdEx(command, workingDir = repoRoot)
  if build.exitCode != 0:
    echo build.output
  doAssert build.exitCode == 0, "Failed to compile src/nobby.nim."

proc firstHrefPath(html: string, marker: string): string =
  ## Returns first href path that starts with marker.
  let token = "href=\"" & marker
  let startPos = html.find(token)
  if startPos < 0:
    return ""
  let hrefStart = startPos + 6
  let hrefEnd = html.find('"', hrefStart)
  if hrefEnd <= hrefStart:
    return ""
  result = html[hrefStart ..< hrefEnd]

proc postForm(client: Curly, path: string, data: seq[(string, string)]): Response =
  ## Posts x-www-form-urlencoded data and returns response.
  var query: QueryParams
  for (key, value) in data:
    query.add((key, value))
  var headers: HttpHeaders
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  client.post(BaseUrl & path, headers, $query)

proc postFormWithHeaders(
  client: Curly,
  path: string,
  data: seq[(string, string)],
  headers: HttpHeaders
): Response =
  ## Posts x-www-form-urlencoded data with caller-provided headers.
  var query: QueryParams
  for (key, value) in data:
    query.add((key, value))
  var merged = headers
  merged["Content-Type"] = "application/x-www-form-urlencoded"
  client.post(BaseUrl & path, merged, $query)

proc postMultipartForm(client: Curly, path: string, data: seq[(string, string)]): Response =
  ## Posts multipart/form-data and returns response.
  var entries: seq[MultipartEntry]
  for (key, value) in data:
    entries.add(MultipartEntry(name: key, payload: value))
  let (contentType, body) = encodeMultipart(entries)
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  client.post(BaseUrl & path, headers, body)

proc postMultipartFormWithHeaders(
  client: Curly,
  path: string,
  data: seq[(string, string)],
  headers: HttpHeaders
): Response =
  ## Posts multipart/form-data with caller-provided headers.
  var entries: seq[MultipartEntry]
  for (key, value) in data:
    entries.add(MultipartEntry(name: key, payload: value))
  let (contentType, body) = encodeMultipart(entries)
  var merged = headers
  merged["Content-Type"] = contentType
  client.post(BaseUrl & path, merged, body)

proc extractCookie(setCookieValue: string): string =
  ## Extracts "name=value" from one Set-Cookie header.
  let stop = setCookieValue.find(';')
  if stop > 0:
    return setCookieValue[0 ..< stop]
  setCookieValue

proc main() =
  ## Runs an integration smoke test against key forum flows.
  let repoRoot = getCurrentDir()
  let curl = newCurly()
  defer:
    curl.close()
  stopExistingServer(curl)
  ensurePortIsFree(curl)
  let tempRoot = repoRoot / "tests" / ".tmp-e2e"
  if dirExists(tempRoot):
    removeDir(tempRoot)
  createDir(tempRoot)
  let tempServerExe =
    when defined(windows):
      tempRoot / "nobby-test.exe"
    else:
      tempRoot / "nobby-test"
  compileServer(repoRoot, tempServerExe)
  doAssert fileExists(tempServerExe), "Server executable not found at " & tempServerExe

  var server = startProcess(
    command = tempServerExe,
    workingDir = tempRoot,
    options = {poStdErrToStdOut}
  )
  defer:
    if server.running():
      server.terminate()
      sleep(200)
      if server.running():
        server.kill()
    close(server)

  waitForServer(curl, server)

  echo "Testing index page."
  let indexHtml = curl.get(BaseUrl & "/").body
  doAssert "Index" in indexHtml, "Index page heading missing."
  doAssert "Topics" in indexHtml, "Index topics column missing."
  doAssert "Posts" in indexHtml, "Index posts column missing."
  doAssert "Last Post" in indexHtml, "Index last-post column missing."
  doAssert "General Discussions" in indexHtml, "Index section header missing."
  doAssert "Users:" in indexHtml, "Index users stat missing."

  let boardPath = firstHrefPath(indexHtml, "/b/")
  doAssert boardPath.len > 0, "Could not find a board link on index page."

  echo "Testing board page."
  let boardHtml = curl.get(BaseUrl & boardPath).body
  doAssert "Thread" in boardHtml, "Board thread column missing."
  doAssert "You must be logged in to post." in boardHtml, "Board should require login to post."

  echo "Testing register flow."
  let accountName = "e2e_account_" & $epochTime().int64
  let accountEmail = accountName & "@example.com"
  let firstPassword = "Passw0rdOne!"
  let secondPassword = "Passw0rdTwo!"
  let registerRes = postForm(curl, "/register", @[
    ("username", accountName),
    ("email", accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ])
  doAssert registerRes.code in [200, 302, 405],
    "Register request failed with code " & $registerRes.code & ". Body:\n" & registerRes.body
  let caseVariantName = accountName[0].toUpperAscii() & accountName[1 .. ^1]
  let caseVariantRes = postForm(curl, "/register", @[
    ("username", caseVariantName),
    ("email", "variant_" & accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ])
  doAssert caseVariantRes.code == 400, "Case-variant username should be rejected."
  doAssert "Username is already taken." in caseVariantRes.body,
    "Case-variant username should return username taken error."
  var accountUserId = ""
  let accountDbPool = newPool()
  accountDbPool.add(openDatabase(tempRoot / "forum.db"))
  accountDbPool.withDb:
    let accountRows = db.query(
      "SELECT id FROM account_user WHERE username = ? AND email = ? LIMIT 1",
      accountName,
      accountEmail
    )
    doAssert accountRows.len == 1 and accountRows[0].len > 0, "Register did not create account_user row."
    accountUserId = accountRows[0][0]

  echo "Testing login validation."
  let badLogin = postForm(curl, "/login", @[
    ("username", accountName),
    ("password", "NotTheRightPassword")
  ])
  doAssert badLogin.code in [401, 200], "Bad login should be rejected."
  doAssert "Invalid username or password." in badLogin.body, "Bad login message missing."

  let goodLogin = postForm(curl, "/login", @[
    ("username", accountName),
    ("password", firstPassword)
  ])
  doAssert goodLogin.code in [200, 302, 405], "Good login failed."
  let sessionCookie = extractCookie(goodLogin.headers["Set-Cookie"])
  doAssert sessionCookie.startsWith("nobby_session="), "Login did not return session cookie."
  var authHeaders: HttpHeaders
  authHeaders["Cookie"] = sessionCookie

  let otherAccountName = accountName & "_other"
  let otherAccountEmail = otherAccountName & "@example.com"
  let otherRegisterRes = postForm(curl, "/register", @[
    ("username", otherAccountName),
    ("email", otherAccountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ])
  doAssert otherRegisterRes.code in [200, 302, 405], "Second account register failed."

  echo "Testing user profile page and edit flow."
  let otherUserPage = curl.get(BaseUrl & "/u/" & otherAccountName, authHeaders).body
  doAssert otherAccountName in otherUserPage, "Should be able to view another user's profile."
  doAssert "Edit profile" notin otherUserPage, "Other user's profile should not show edit link."
  let userPageBeforeEdit = curl.get(BaseUrl & "/u/" & accountName, authHeaders).body
  doAssert accountName in userPageBeforeEdit, "User page should show username."
  doAssert "Posts:" in userPageBeforeEdit and "Comments:" in userPageBeforeEdit,
    "User page should show post and comment counts."
  doAssert "Edit profile" in userPageBeforeEdit, "Own profile should show edit link."
  let editPage = curl.get(BaseUrl & "/u/" & accountName & "/edit", authHeaders)
  doAssert editPage.code == 200, "Edit user page should load for current user."
  let forbiddenEditPage = curl.get(BaseUrl & "/u/" & otherAccountName & "/edit", authHeaders)
  doAssert forbiddenEditPage.code == 403, "Editing another profile page should be forbidden."
  let statusText = "Orbiting around Nim."
  let bioText = "I build retro forums in Nim."
  let editSave = postFormWithHeaders(curl, "/u/" & accountName & "/edit", @[
    ("userStatus", statusText),
    ("userBio", bioText)
  ], authHeaders)
  doAssert editSave.code in [200, 302, 405], "Edit profile submit failed."
  let forbiddenEditSave = postFormWithHeaders(curl, "/u/" & otherAccountName & "/edit", @[
    ("userStatus", "Should not save"),
    ("userBio", "Should not save")
  ], authHeaders)
  doAssert forbiddenEditSave.code == 403, "Editing another profile submit should be forbidden."
  let userPageAfterEdit = curl.get(BaseUrl & "/u/" & accountName, authHeaders).body
  doAssert statusText in userPageAfterEdit, "User status should be saved."
  doAssert bioText in userPageAfterEdit, "User bio should be saved."

  echo "Testing users page email visibility rules."
  let usersAsGuest = curl.get(BaseUrl & "/users").body
  doAssert accountName in usersAsGuest, "Users page should list registered accounts."
  doAssert accountEmail notin usersAsGuest, "Guest users should not see account emails."
  doAssert "Index" in usersAsGuest and "Users" in usersAsGuest and " > " in usersAsGuest,
    "Users page should show breadcrumb."
  doAssert "Page" in usersAsGuest and "of" in usersAsGuest, "Users page should render pagination summary."
  accountDbPool.withDb:
    discard db.query("UPDATE account_user SET is_admin = 1 WHERE username = ?", accountName)
  let usersAsAdmin = curl.get(BaseUrl & "/users", authHeaders).body
  doAssert accountEmail in usersAsAdmin, "Admin users should see account emails."

  echo "Testing topic creation."
  let createdTitle = "E2E topic title"
  let createdBody = "E2E topic body line 1.\nE2E topic body line 2.\nE2E topic body line 3.\nE2E topic body line 4."
  let shortTopicBody = "short topic line"
  let shortTopicCreate = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("author", "E2EUser"),
    ("title", "E2E short topic"),
    ("body", shortTopicBody)
  ], authHeaders)
  doAssert shortTopicCreate.code == 400, "One-line topic should be rejected."
  doAssert "Message must be at least 4 lines." in shortTopicCreate.body,
    "Short topic rejection message missing."
  let topicCreate = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("author", "E2EUser"),
    ("title", createdTitle),
    ("body", createdBody)
  ], authHeaders)
  doAssert topicCreate.code in [200, 302, 405], "Expected success, redirect, or redirect-follow method mismatch after topic create. Got " & $topicCreate.code
  let topicPath =
    if topicCreate.code == 302:
      topicCreate.headers["Location"]
    else:
      parseUrl(topicCreate.url).path
  doAssert topicPath.startsWith("/t/"), "Missing topic redirect location."

  echo "Testing topic page."
  let topicHtml = curl.get(BaseUrl & topicPath).body
  doAssert createdTitle in topicHtml, "Created topic title not found."
  doAssert createdBody in topicHtml, "Created topic body not found."
  doAssert statusText in topicHtml, "User status should appear under author on topic page."

  echo "Testing reply submission."
  let replyBody = "E2E reply line 1.\nE2E reply line 2.\nE2E reply line 3.\nE2E reply line 4."
  let shortReplyBody = "short reply line"
  let shortReplyCreate = postFormWithHeaders(curl, topicPath & "/reply", @[
    ("author", "E2EReplyUser"),
    ("body", shortReplyBody)
  ], authHeaders)
  doAssert shortReplyCreate.code == 400, "One-line reply should be rejected."
  doAssert "Reply must be at least 4 lines." in shortReplyCreate.body,
    "Short reply rejection message missing."
  let replyCreate = postFormWithHeaders(curl, topicPath & "/reply", @[
    ("author", "E2EReplyUser"),
    ("body", replyBody)
  ], authHeaders)
  doAssert replyCreate.code in [200, 302, 405], "Expected success, redirect, or redirect-follow method mismatch after reply submission."

  echo "Testing reply visibility."
  let topicAfterReply = curl.get(BaseUrl & topicPath).body
  doAssert replyBody in topicAfterReply, "Reply body not visible after posting."

  echo "Testing cookie-authenticated posting attribution."
  let authTopicTitle = "E2E auth topic"
  let authTopicBody = "E2E auth topic line 1.\nE2E auth topic line 2.\nE2E auth topic line 3.\nE2E auth topic line 4."
  let authTopicCreate = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("author", "SpoofAuthorShouldNotAppear"),
    ("title", authTopicTitle),
    ("body", authTopicBody)
  ], authHeaders)
  doAssert authTopicCreate.code in [200, 302, 405], "Authenticated topic create failed."
  let authTopicPath =
    if authTopicCreate.code == 302:
      authTopicCreate.headers["Location"]
    else:
      parseUrl(authTopicCreate.url).path
  let authTopicHtml = curl.get(BaseUrl & authTopicPath).body
  doAssert accountName in authTopicHtml, "Logged-in username not used for posting."
  doAssert "SpoofAuthorShouldNotAppear" notin authTopicHtml, "Form author should be ignored while logged in."

  echo "Testing logout and guest posting attribution."
  let logoutRes = postFormWithHeaders(curl, "/logout", @[], authHeaders)
  doAssert logoutRes.code in [200, 302, 405], "Logout request failed."
  let guestTopicCreate = postMultipartForm(curl, boardPath & "/new", @[
    ("author", "GuestAfterLogout"),
    ("title", "E2E guest topic"),
    ("body", "E2E guest topic body")
  ])
  doAssert guestTopicCreate.code == 401, "Guest topic create should be blocked."

  echo "Testing forgot-password and reset-password flow."
  let forgotPasswordRes = postForm(curl, "/forgot-password", @[
    ("email", accountEmail)
  ])
  doAssert forgotPasswordRes.code == 200, "Forgot-password request should succeed."
  doAssert "If that email exists, a reset message was sent." in forgotPasswordRes.body,
    "Forgot-password confirmation missing."

  var resetToken = ""
  let dbPool = newPool()
  dbPool.add(openDatabase(tempRoot / "forum.db"))
  dbPool.withDb:
    let resetRows = db.query(
      "SELECT token FROM password_reset_token WHERE user_id = ? ORDER BY id DESC LIMIT 1",
      accountUserId
    )
    doAssert resetRows.len == 1 and resetRows[0].len > 0, "No password reset token was generated."
    resetToken = resetRows[0][0]

  let resetRes = postForm(curl, "/reset-password", @[
    ("token", resetToken),
    ("password", secondPassword),
    ("repeatPassword", secondPassword)
  ])
  doAssert resetRes.code in [200, 302, 405], "Reset-password request failed."

  let oldLogin = postForm(curl, "/login", @[
    ("username", accountName),
    ("password", firstPassword)
  ])
  doAssert oldLogin.code in [401, 200], "Old password should no longer work."
  doAssert "Invalid username or password." in oldLogin.body, "Old-password rejection missing."

  let newLogin = postForm(curl, "/login", @[
    ("username", accountName),
    ("password", secondPassword)
  ])
  doAssert newLogin.code in [200, 302, 405], "New password login failed."

  echo "Testing forgot-username flow."
  let forgotUsernameRes = postForm(curl, "/forgot-username", @[
    ("email", accountEmail)
  ])
  doAssert forgotUsernameRes.code == 200, "Forgot-username request should succeed."
  doAssert "If that email exists, a username reminder was sent." in forgotUsernameRes.body,
    "Forgot-username confirmation missing."

  echo "All integration checks passed."

when isMainModule:
  main()
