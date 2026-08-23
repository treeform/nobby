import
  std/[os, osproc, streams, strutils, times],
  debby/[pools, sqlite],
  webby,
  curly,
  ../src/nobby/[accounts, models, utils]

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

proc extractNamedCookie(headers: HttpHeaders, cookieName: string): string =
  ## Finds one Set-Cookie pair by cookie name.
  for (key, value) in headers:
    if cmpIgnoreCase(key, "Set-Cookie") != 0:
      continue
    let pair = extractCookie(value)
    if pair.startsWith(cookieName & "="):
      return pair

proc mergeCookieHeader(existing: string, pair: string): string =
  ## Merges one cookie pair into a Cookie header value.
  if pair.len == 0:
    return existing
  if existing.len == 0:
    return pair
  existing & "; " & pair

proc extractInputValue(html: string, fieldName: string): string =
  ## Returns the value attribute for the first matching input name.
  let nameToken = "name=\"" & fieldName & "\""
  let namePos = html.find(nameToken)
  if namePos < 0:
    return ""
  let valueToken = "value=\""
  let valuePos = html.find(valueToken, namePos)
  if valuePos < 0:
    return ""
  let valueStart = valuePos + valueToken.len
  let valueEnd = html.find('"', valueStart)
  if valueEnd <= valueStart:
    return ""
  html[valueStart ..< valueEnd]

proc loadGuestCsrf(
  client: Curly,
  path: string,
  headers: var HttpHeaders
): string =
  ## Loads a CSRF token from a guest page and stores the cookie.
  let page = client.get(BaseUrl & path, headers)
  result = extractInputValue(page.body, "csrf")
  doAssert result.len > 0, "Missing csrf field on " & path
  let csrfCookie = extractNamedCookie(page.headers, "nobby_csrf")
  if csrfCookie.len > 0:
    if "Cookie" in headers:
      headers["Cookie"] = mergeCookieHeader(headers["Cookie"], csrfCookie)
    else:
      headers["Cookie"] = csrfCookie
  doAssert "Cookie" in headers and "nobby_csrf=" in headers["Cookie"],
    "Missing nobby_csrf cookie after loading " & path

proc main() =
  ## Runs an integration smoke test against key forum flows.
  let repoRoot = getCurrentDir()
  let curl = newCurly()
  defer:
    curl.close()
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

  echo "Testing syncUserCounters preserves updated_at."
  let counterPool = newForumPool(tempRoot / "counters.db", 1)
  initSchema(counterPool)
  initAccountsSchema(counterPool)
  seedDefaultBoard(counterPool)
  let counterUser = counterPool.createUser(
    "test-server-secret",
    "counter_user",
    "counter_user@example.com",
    "Passw0rdOne!"
  )
  const FixedUpdatedAt = 1_700_000_000'i64
  counterPool.withDb:
    discard db.query(
      """
      UPDATE account_user
      SET updated_at = ?, thread_count = 0, post_count = 0
      WHERE id = ?
      """,
      FixedUpdatedAt,
      counterUser.id
    )
  counterPool.syncUserCounters()
  counterPool.withDb:
    let unchangedRows = db.query(
      """
      SELECT updated_at, thread_count, post_count
      FROM account_user WHERE id = ?
      """,
      counterUser.id
    )
    doAssert unchangedRows.len == 1, "Counter user row missing."
    doAssert unchangedRows[0][0] == $FixedUpdatedAt,
      "Matching counters should leave updated_at alone."
    doAssert unchangedRows[0][1] == "0", "Thread count should stay 0."
    doAssert unchangedRows[0][2] == "0", "Post count should stay 0."
  var topic = Topic(
    boardId: counterPool.listBoards()[0].id,
    title: "Counter topic",
    authorName: counterUser.username,
    createdAt: FixedUpdatedAt,
    updatedAt: FixedUpdatedAt
  )
  counterPool.insert(topic)
  var post = Post(
    topicId: topic.id,
    authorName: counterUser.username,
    body: "Counter body\nline 2\nline 3\nline 4",
    createdAt: FixedUpdatedAt
  )
  counterPool.insert(post)
  counterPool.syncUserCounters()
  var syncedUpdatedAt = ""
  counterPool.withDb:
    let syncedRows = db.query(
      """
      SELECT updated_at, thread_count, post_count
      FROM account_user WHERE id = ?
      """,
      counterUser.id
    )
    doAssert syncedRows.len == 1, "Counter user row missing after sync."
    doAssert syncedRows[0][1] == "1", "Thread count should recompute to 1."
    doAssert syncedRows[0][2] == "1", "Post count should recompute to 1."
    doAssert syncedRows[0][0] != $FixedUpdatedAt,
      "Changed counters should refresh updated_at."
    syncedUpdatedAt = syncedRows[0][0]
  counterPool.syncUserCounters()
  counterPool.withDb:
    let stableRows = db.query(
      "SELECT updated_at FROM account_user WHERE id = ?",
      counterUser.id
    )
    doAssert stableRows.len == 1, "Counter user row missing after second sync."
    doAssert stableRows[0][0] == syncedUpdatedAt,
      "Second sync with matching counters should keep updated_at."

  echo "Testing createUser rejects invalid usernames."
  var invalidCreateRaised = false
  try:
    discard counterPool.createUser(
      "test-server-secret",
      "<script>",
      "xss@example.com",
      "Passw0rdOne!"
    )
  except ValueError:
    invalidCreateRaised = true
  doAssert invalidCreateRaised, "createUser should raise ValueError for bad usernames."

  echo "Testing UTF-8 safe truncation."
  let midRune = "a" & "日"
  doAssert midRune.len == 4, "Expected one ASCII byte plus a 3-byte rune."
  let cut = truncateUtf8(midRune, 2)
  doAssert cut == "a", "Mid-rune cut should drop the partial rune."
  doAssert cut.len == 1, "Truncated result should be valid UTF-8."
  doAssert cleanUserStatus("x".repeat(141) & "日") == "x".repeat(140),
    "cleanUserStatus should truncate on a byte boundary."
  doAssert cleanUserBio("日".repeat(2000)).len <= 4000,
    "cleanUserBio should stay within the byte budget."
  doAssert cleanUserBio("日".repeat(2000)).len mod 3 == 0,
    "cleanUserBio should not split a 3-byte rune."

  echo "Testing markdown URL scheme allow-list."
  let badLinkHtml = renderSafeMarkdown("[x](javascript:alert(1))")
  doAssert "javascript:" notin badLinkHtml.toLowerAscii(),
    "javascript: href should be neutralized."
  doAssert "href=\"#\"" in badLinkHtml, "Unsafe href should become #."
  let badImgHtml = renderSafeMarkdown("![x](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)")
  doAssert "data:" notin badImgHtml.toLowerAscii(),
    "data: image src should be neutralized."
  let goodLinkHtml = renderSafeMarkdown("[ok](https://example.com/a)")
  doAssert "href=\"https://example.com/a\"" in goodLinkHtml,
    "https links should remain."
  let mailHtml = renderSafeMarkdown("[mail](mailto:a@example.com)")
  doAssert "href=\"mailto:a@example.com\"" in mailHtml,
    "mailto links should remain."
  let relativeHtml = renderSafeMarkdown("[rel](/b/main)")
  doAssert "href=\"/b/main\"" in relativeHtml,
    "Relative links should remain."

  echo "Testing SQLite WAL and busy lock helpers."
  let walPool = newForumPool(tempRoot / "wal.db", 2)
  initSchema(walPool)
  initAccountsSchema(walPool)
  walPool.withDb:
    let modeRows = db.query("PRAGMA journal_mode")
    doAssert modeRows.len == 1 and modeRows[0][0].toLowerAscii() == "wal",
      "Forum pool should enable WAL mode."
    let busyRows = db.query("PRAGMA busy_timeout")
    doAssert busyRows.len == 1 and busyRows[0][0] == "5000",
      "Forum pool should set busy_timeout to 5000ms."
  doAssert isBusyLockError(newException(DbError, "SQLite: database is locked")),
    "Locked errors should be detected as busy."
  doAssert not isBusyLockError(newException(DbError, "UNIQUE constraint failed")),
    "Unique errors should not be treated as busy."

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
  var guestHeaders: HttpHeaders
  let registerWithoutCsrf = postForm(curl, "/register", @[
    ("username", accountName & "_nocsrf"),
    ("email", accountName & "_nocsrf@example.com"),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ])
  doAssert registerWithoutCsrf.code == 403,
    "Register without csrf should be rejected."
  let registerCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let registerRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", registerCsrf),
    ("username", accountName),
    ("email", accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert registerRes.code in [200, 302, 405],
    "Register request failed with code " & $registerRes.code & ". Body:\n" & registerRes.body
  let unicodeCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let unicodeNameRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", unicodeCsrf),
    ("username", "usérname"),
    ("email", "unicode_" & accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert unicodeNameRes.code == 400, "Unicode username should be rejected."
  doAssert "ASCII letters" in unicodeNameRes.body,
    "Unicode username should return ASCII validation error."
  let spacedCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let spacedNameRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", spacedCsrf),
    ("username", "bad name"),
    ("email", "space_" & accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert spacedNameRes.code == 400, "Spaced username should be rejected."
  doAssert "ASCII letters" in spacedNameRes.body,
    "Spaced username should return ASCII validation error."
  let caseVariantName = accountName[0].toUpperAscii() & accountName[1 .. ^1]
  let caseCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let caseVariantRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", caseCsrf),
    ("username", caseVariantName),
    ("email", "variant_" & accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert caseVariantRes.code == 400, "Case-variant username should be rejected."
  doAssert "Username is already taken." in caseVariantRes.body,
    "Case-variant username should return username taken error."
  let dupCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let duplicateEmailRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", dupCsrf),
    ("username", accountName & "_dup"),
    ("email", accountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert duplicateEmailRes.code == 400, "Duplicate email should be rejected."
  doAssert "Email is already registered." in duplicateEmailRes.body,
    "Duplicate email should return email registered error."
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
    let indexRows = db.query(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'account_user'"
    )
    var
      hasUsernameUnique = false
      hasEmailUnique = false
    for indexRow in indexRows:
      if indexRow.len == 0:
        continue
      if indexRow[0] == "idx_account_user_username_lower":
        hasUsernameUnique = true
      if indexRow[0] == "idx_account_user_email_unique":
        hasEmailUnique = true
    doAssert hasUsernameUnique, "Missing unique lower(username) index."
    doAssert hasEmailUnique, "Missing unique email index."
    var uniqueInsertFailed = false
    try:
      discard db.query(
        "INSERT INTO account_user (username, email, is_admin, thread_count, post_count, user_status, user_bio, password_salt, password_hash, password_iterations, created_at, updated_at) VALUES (?, ?, 0, 0, 0, '', '', 'salt', 'hash', 1, 0, 0)",
        accountName & "_raw",
        accountEmail
      )
    except:
      uniqueInsertFailed = true
    doAssert uniqueInsertFailed, "Raw duplicate email insert should hit UNIQUE constraint."

  echo "Testing login validation."
  let loginWithoutCsrf = postForm(curl, "/login", @[
    ("username", accountName),
    ("password", firstPassword)
  ])
  doAssert loginWithoutCsrf.code == 403, "Login without csrf should be rejected."
  let badLoginCsrf = loadGuestCsrf(curl, "/login", guestHeaders)
  let badLogin = postFormWithHeaders(curl, "/login", @[
    ("csrf", badLoginCsrf),
    ("username", accountName),
    ("password", "NotTheRightPassword")
  ], guestHeaders)
  doAssert badLogin.code in [401, 200], "Bad login should be rejected."
  doAssert "Invalid username or password." in badLogin.body, "Bad login message missing."

  let goodLoginCsrf = loadGuestCsrf(curl, "/login", guestHeaders)
  let goodLogin = postFormWithHeaders(curl, "/login", @[
    ("csrf", goodLoginCsrf),
    ("username", accountName),
    ("password", firstPassword)
  ], guestHeaders)
  doAssert goodLogin.code in [200, 302, 405], "Good login failed."
  var sessionSetCookie = ""
  for (key, value) in goodLogin.headers:
    if cmpIgnoreCase(key, "Set-Cookie") == 0 and value.startsWith("nobby_session="):
      sessionSetCookie = value
      break
  doAssert sessionSetCookie.len > 0, "Login did not return session cookie."
  doAssert "HttpOnly" in sessionSetCookie, "Session cookie should be HttpOnly."
  doAssert "SameSite=Lax" in sessionSetCookie, "Session cookie should use SameSite=Lax."
  doAssert "Max-Age=" in sessionSetCookie, "Session cookie should set Max-Age."
  doAssert "Secure" notin sessionSetCookie,
    "Local HTTP tests should omit Secure unless NOBBY_SECURE_COOKIES is set."
  let sessionCookie = extractCookie(sessionSetCookie)
  doAssert sessionCookie.startsWith("nobby_session="), "Login did not return session cookie."
  var authHeaders: HttpHeaders
  authHeaders["Cookie"] = sessionCookie

  echo "Testing CSRF protections."
  let loginPageHtml = curl.get(BaseUrl & "/login").body
  doAssert "name=\"csrf\"" in loginPageHtml, "Login form should include a csrf field."
  let registerPageHtml = curl.get(BaseUrl & "/register").body
  doAssert "name=\"csrf\"" in registerPageHtml, "Register form should include a csrf field."
  let boardWithSession = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "name=\"csrf\"" in boardWithSession, "Authenticated topic form should include a csrf field."
  let csrfFromBoard = extractInputValue(boardWithSession, "csrf")
  doAssert csrfFromBoard.len > 0, "Authenticated topic form should include a csrf value."

  let getLogout = curl.get(BaseUrl & "/logout", authHeaders)
  doAssert getLogout.code in [403, 405],
    "GET /logout should be rejected, got " & $getLogout.code
  let stillLoggedIn = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "You must be logged in to post." notin stillLoggedIn,
    "GET /logout must not clear the session."

  let logoutWithoutCsrf = postFormWithHeaders(curl, "/logout", @[], authHeaders)
  doAssert logoutWithoutCsrf.code == 403, "Logout without csrf should be rejected."
  let stillLoggedInAfterBadLogout = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "You must be logged in to post." notin stillLoggedInAfterBadLogout,
    "Logout without csrf must not clear the session."

  let topicWithoutCsrf = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("title", "CSRF should block this topic"),
    ("body", "line 1\nline 2\nline 3\nline 4")
  ], authHeaders)
  doAssert topicWithoutCsrf.code == 403, "Topic create without csrf should be rejected."

  let replyWithoutCsrf = postFormWithHeaders(curl, "/t/1/reply", @[
    ("body", "line 1\nline 2\nline 3\nline 4")
  ], authHeaders)
  doAssert replyWithoutCsrf.code in [403, 404],
    "Reply without csrf should be rejected, got " & $replyWithoutCsrf.code

  let editWithoutCsrf = postFormWithHeaders(curl, "/u/" & accountName & "/edit", @[
    ("userStatus", "csrf should block"),
    ("userBio", "csrf should block")
  ], authHeaders)
  doAssert editWithoutCsrf.code == 403, "Profile edit without csrf should be rejected."

  let forgotWithoutCsrf = postForm(curl, "/forgot-password", @[
    ("email", accountEmail)
  ])
  doAssert forgotWithoutCsrf.code == 403,
    "Forgot-password without csrf should be rejected."
  let resetWithoutCsrf = postForm(curl, "/reset-password", @[
    ("token", "unused"),
    ("password", secondPassword),
    ("repeatPassword", secondPassword)
  ])
  doAssert resetWithoutCsrf.code == 403,
    "Reset-password without csrf should be rejected."
  let forgotUsernameWithoutCsrf = postForm(curl, "/forgot-username", @[
    ("email", accountEmail)
  ])
  doAssert forgotUsernameWithoutCsrf.code == 403,
    "Forgot-username without csrf should be rejected."

  let csrfBootstrap = curl.get(BaseUrl & boardPath, authHeaders)
  let csrfToken = extractInputValue(csrfBootstrap.body, "csrf")
  doAssert csrfToken.len > 0, "Could not load csrf token for authenticated posts."
  let csrfCookie = extractNamedCookie(csrfBootstrap.headers, "nobby_csrf")
  if csrfCookie.len > 0:
    authHeaders["Cookie"] = mergeCookieHeader(authHeaders["Cookie"], csrfCookie)
  elif "nobby_csrf=" notin authHeaders["Cookie"]:
    doAssert false, "Authenticated board response did not provide nobby_csrf cookie."

  let otherAccountName = accountName & "_other"
  let otherAccountEmail = otherAccountName & "@example.com"
  let otherRegisterCsrf = loadGuestCsrf(curl, "/register", guestHeaders)
  let otherRegisterRes = postFormWithHeaders(curl, "/register", @[
    ("csrf", otherRegisterCsrf),
    ("username", otherAccountName),
    ("email", otherAccountEmail),
    ("password", firstPassword),
    ("repeatPassword", firstPassword)
  ], guestHeaders)
  doAssert otherRegisterRes.code in [200, 302, 405], "Second account register failed."

  echo "Testing user profile page and edit flow."
  let otherUserPage = curl.get(BaseUrl & "/u/" & otherAccountName, authHeaders).body
  doAssert otherAccountName in otherUserPage, "Should be able to view another user's profile."
  doAssert "Edit profile" notin otherUserPage, "Other user's profile should not show edit link."
  let userPageBeforeEdit = curl.get(BaseUrl & "/u/" & accountName, authHeaders).body
  doAssert accountName in userPageBeforeEdit, "User page should show username."
  doAssert "Threads:" in userPageBeforeEdit and "Replies:" in userPageBeforeEdit,
    "User page should show thread and reply counts."
  doAssert "Posts:" in userPageBeforeEdit, "User page should show total post count."
  doAssert "Edit profile" in userPageBeforeEdit, "Own profile should show edit link."
  let editPage = curl.get(BaseUrl & "/u/" & accountName & "/edit", authHeaders)
  doAssert editPage.code == 200, "Edit user page should load for current user."
  let forbiddenEditPage = curl.get(BaseUrl & "/u/" & otherAccountName & "/edit", authHeaders)
  doAssert forbiddenEditPage.code == 403, "Editing another profile page should be forbidden."
  let statusText = "Orbiting around Nim."
  let bioText = "I build retro forums in Nim."
  let editSave = postFormWithHeaders(curl, "/u/" & accountName & "/edit", @[
    ("csrf", csrfToken),
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
    ("csrf", csrfToken),
    ("author", "E2EUser"),
    ("title", "E2E short topic"),
    ("body", shortTopicBody)
  ], authHeaders)
  doAssert shortTopicCreate.code == 400, "One-line topic should be rejected."
  doAssert "Message must be at least 4 lines." in shortTopicCreate.body,
    "Short topic rejection message missing."
  let topicCreate = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("csrf", csrfToken),
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
    ("csrf", csrfToken),
    ("author", "E2EReplyUser"),
    ("body", shortReplyBody)
  ], authHeaders)
  doAssert shortReplyCreate.code == 400, "One-line reply should be rejected."
  doAssert "Reply must be at least 4 lines." in shortReplyCreate.body,
    "Short reply rejection message missing."
  let replyCreate = postFormWithHeaders(curl, topicPath & "/reply", @[
    ("csrf", csrfToken),
    ("author", "E2EReplyUser"),
    ("body", replyBody)
  ], authHeaders)
  doAssert replyCreate.code in [200, 302, 405], "Expected success, redirect, or redirect-follow method mismatch after reply submission."

  echo "Testing reply visibility."
  let topicAfterReply = curl.get(BaseUrl & topicPath).body
  doAssert replyBody in topicAfterReply, "Reply body not visible after posting."

  echo "Testing reply redirect to last page."
  let topicIdForPaging = topicPath.split('/')[^1]
  accountDbPool.withDb:
    let baseTs = epochTime().int64 - 1000
    for i in 1 .. 19:
      discard db.query(
        "INSERT INTO post (topic_id, author_name, body, created_at) VALUES (?, ?, ?, ?)",
        topicIdForPaging,
        accountName,
        "Pager filler " & $i & "\nline 2\nline 3\nline 4",
        baseTs + i
      )
  let pagedReplyMarker = "PagedReplyMarker" & $epochTime().int64
  let pagedReplyBody =
    pagedReplyMarker & " line 1.\nPaged reply line 2.\nPaged reply line 3.\nPaged reply line 4."
  let pagedReplyCreate = postFormWithHeaders(curl, topicPath & "/reply", @[
    ("csrf", csrfToken),
    ("body", pagedReplyBody)
  ], authHeaders)
  doAssert pagedReplyCreate.code in [200, 302, 405],
    "Paged reply failed with code " & $pagedReplyCreate.code & ". Body:\n" &
    pagedReplyCreate.body
  if pagedReplyCreate.code == 302:
    doAssert pagedReplyCreate.headers["Location"] == topicPath & "?page=2",
      "Reply should redirect to last page, got " & pagedReplyCreate.headers["Location"]
  elif pagedReplyCreate.code in [200, 405]:
    doAssert "page=2" in pagedReplyCreate.url,
      "Followed reply redirect should land on page 2, got " & pagedReplyCreate.url
  let lastPageHtml = curl.get(BaseUrl & topicPath & "?page=2").body
  doAssert pagedReplyMarker in lastPageHtml, "New reply should be visible on last page."
  let firstPageHtml = curl.get(BaseUrl & topicPath & "?page=1").body
  doAssert pagedReplyMarker notin firstPageHtml,
    "New reply should not appear on first page when paginated."

  echo "Testing cookie-authenticated posting attribution."
  let authTopicTitle = "E2E auth topic"
  let authTopicBody = "E2E auth topic line 1.\nE2E auth topic line 2.\nE2E auth topic line 3.\nE2E auth topic line 4."
  let authTopicCreate = postMultipartFormWithHeaders(curl, boardPath & "/new", @[
    ("csrf", csrfToken),
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

  echo "Testing topic lock and hot icons."
  var otherGuestHeaders: HttpHeaders
  let otherLoginCsrf = loadGuestCsrf(curl, "/login", otherGuestHeaders)
  let otherLogin = postFormWithHeaders(curl, "/login", @[
    ("csrf", otherLoginCsrf),
    ("username", otherAccountName),
    ("password", firstPassword)
  ], otherGuestHeaders)
  doAssert otherLogin.code in [200, 302, 405], "Other account login failed."
  let otherSessionCookie = extractNamedCookie(otherLogin.headers, "nobby_session")
  doAssert otherSessionCookie.startsWith("nobby_session="), "Other login missing session."
  var otherAuthHeaders: HttpHeaders
  otherAuthHeaders["Cookie"] = otherSessionCookie
  let otherBoard = curl.get(BaseUrl & boardPath, otherAuthHeaders)
  let otherCsrf = extractInputValue(otherBoard.body, "csrf")
  doAssert otherCsrf.len > 0, "Other user board page should include csrf."
  let otherCsrfCookie = extractNamedCookie(otherBoard.headers, "nobby_csrf")
  if otherCsrfCookie.len > 0:
    otherAuthHeaders["Cookie"] = mergeCookieHeader(otherAuthHeaders["Cookie"], otherCsrfCookie)
  let nonAdminLock = postFormWithHeaders(curl, authTopicPath & "/lock", @[
    ("csrf", otherCsrf)
  ], otherAuthHeaders)
  doAssert nonAdminLock.code == 403, "Non-admin lock should be forbidden."
  let adminTopicPage = curl.get(BaseUrl & authTopicPath, authHeaders).body
  doAssert "Lock topic" in adminTopicPage, "Admin should see lock control."
  let lockRes = postFormWithHeaders(curl, authTopicPath & "/lock", @[
    ("csrf", csrfToken)
  ], authHeaders)
  doAssert lockRes.code in [200, 302, 405], "Admin lock failed."
  let lockedTopicPage = curl.get(BaseUrl & authTopicPath, authHeaders).body
  doAssert "This topic is locked." in lockedTopicPage, "Locked topic should show notice."
  doAssert "Unlock topic" in lockedTopicPage, "Admin should see unlock control."
  let lockedReply = postFormWithHeaders(curl, authTopicPath & "/reply", @[
    ("csrf", csrfToken),
    ("body", "Should fail line 1.\nline 2\nline 3\nline 4")
  ], authHeaders)
  doAssert lockedReply.code == 403, "Reply to locked topic should be forbidden."
  let boardAfterLock = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "topic-locked.svg" in boardAfterLock, "Locked topic should use locked icon."
  let unlockRes = postFormWithHeaders(curl, authTopicPath & "/unlock", @[
    ("csrf", csrfToken)
  ], authHeaders)
  doAssert unlockRes.code in [200, 302, 405], "Admin unlock failed."
  let unlockedTopicPage = curl.get(BaseUrl & authTopicPath, authHeaders).body
  doAssert "Lock topic" in unlockedTopicPage, "Unlocked topic should show lock control again."
  accountDbPool.withDb:
    let hotTopicId = authTopicPath.split('/')[^1]
    let baseTs = epochTime().int64 - 60
    for i in 1 .. 5:
      discard db.query(
        "INSERT INTO post (topic_id, author_name, body, created_at) VALUES (?, ?, ?, ?)",
        hotTopicId,
        accountName,
        "Hot filler " & $i & "\nline 2\nline 3\nline 4",
        baseTs + i
      )
  let boardAfterHot = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "topic-hot.svg" in boardAfterHot, "Recently active topic should use hot icon."

  echo "Testing forgot-password and reset-password flow."
  let forgotCsrf = loadGuestCsrf(curl, "/forgot-password", guestHeaders)
  let forgotPasswordRes = postFormWithHeaders(curl, "/forgot-password", @[
    ("csrf", forgotCsrf),
    ("email", accountEmail)
  ], guestHeaders)
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

  let stillAuthedBeforeReset = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "You must be logged in to post." notin stillAuthedBeforeReset,
    "Old session should still work before password reset."

  let resetCsrf = loadGuestCsrf(
    curl,
    "/reset-password?token=" & resetToken,
    guestHeaders
  )
  let resetRes = postFormWithHeaders(curl, "/reset-password", @[
    ("csrf", resetCsrf),
    ("token", resetToken),
    ("password", secondPassword),
    ("repeatPassword", secondPassword)
  ], guestHeaders)
  doAssert resetRes.code in [200, 302, 405], "Reset-password request failed."

  let oldSessionAfterReset = curl.get(BaseUrl & boardPath, authHeaders).body
  doAssert "You must be logged in to post." in oldSessionAfterReset,
    "Password reset should revoke existing sessions."

  let oldLoginCsrf = loadGuestCsrf(curl, "/login", guestHeaders)
  let oldLogin = postFormWithHeaders(curl, "/login", @[
    ("csrf", oldLoginCsrf),
    ("username", accountName),
    ("password", firstPassword)
  ], guestHeaders)
  doAssert oldLogin.code in [401, 200], "Old password should no longer work."
  doAssert "Invalid username or password." in oldLogin.body, "Old-password rejection missing."

  let newLoginCsrf = loadGuestCsrf(curl, "/login", guestHeaders)
  let newLogin = postFormWithHeaders(curl, "/login", @[
    ("csrf", newLoginCsrf),
    ("username", accountName),
    ("password", secondPassword)
  ], guestHeaders)
  doAssert newLogin.code in [200, 302, 405], "New password login failed."
  let newSessionCookie = extractNamedCookie(newLogin.headers, "nobby_session")
  doAssert newSessionCookie.startsWith("nobby_session="), "New login should return a session cookie."
  var newAuthHeaders: HttpHeaders
  newAuthHeaders["Cookie"] = newSessionCookie

  echo "Testing logout and guest posting attribution."
  let logoutPage = curl.get(BaseUrl & boardPath, newAuthHeaders)
  let logoutCsrf = extractInputValue(logoutPage.body, "csrf")
  doAssert logoutCsrf.len > 0, "Logged-in board page should include csrf for logout."
  let logoutCsrfCookie = extractNamedCookie(logoutPage.headers, "nobby_csrf")
  if logoutCsrfCookie.len > 0:
    newAuthHeaders["Cookie"] = mergeCookieHeader(newAuthHeaders["Cookie"], logoutCsrfCookie)
  let logoutRes = postFormWithHeaders(curl, "/logout", @[
    ("csrf", logoutCsrf)
  ], newAuthHeaders)
  doAssert logoutRes.code in [200, 302, 405], "Logout request failed."
  let guestTopicCreate = postMultipartForm(curl, boardPath & "/new", @[
    ("author", "GuestAfterLogout"),
    ("title", "E2E guest topic"),
    ("body", "E2E guest topic body")
  ])
  doAssert guestTopicCreate.code == 401, "Guest topic create should be blocked."

  echo "Testing forgot-username flow."
  let forgotUsernameCsrf = loadGuestCsrf(curl, "/forgot-username", guestHeaders)
  let forgotUsernameRes = postFormWithHeaders(curl, "/forgot-username", @[
    ("csrf", forgotUsernameCsrf),
    ("email", accountEmail)
  ], guestHeaders)
  doAssert forgotUsernameRes.code == 200, "Forgot-username request should succeed."
  doAssert "If that email exists, a username reminder was sent." in forgotUsernameRes.body,
    "Forgot-username confirmation missing."

  echo "All integration checks passed."

when isMainModule:
  main()
