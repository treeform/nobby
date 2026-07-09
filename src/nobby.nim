import
  std/strutils,
  webby,
  mummy, mummy/routers,
  nobby/[accounts, models, pages, utils]
const
  PageSize = 20
  ForumCss = staticRead("../data/style.css")
  ForumFolderSvg = staticRead("../data/images/forum-folder.svg")
  ForumPinSvg = staticRead("../data/images/forum-pin.svg")
  TopicSvg = staticRead("../data/images/topic.svg")
  TopicHotSvg = staticRead("../data/images/topic-hot.svg")
  TopicLockedSvg = staticRead("../data/images/topic-locked.svg")

proc parsePositiveInt(value: string): int =
  ## Parses positive integer and returns zero on failure.
  try:
    result = value.parseInt()
    if result < 1:
      result = 0
  except ValueError:
    result = 0

let serverSecretValue = loadServerSecret()

proc serverSecret(): string {.gcsafe.} =
  ## Returns the loaded password pepper for this process.
  {.cast(gcsafe).}:
    result = serverSecretValue

proc pageFromUri(rawUri: string): int =
  ## Reads optional page query from URI using webby parser.
  result = 1
  let parsed = parsePositiveInt(parseUrl(rawUri).query["page"])
  if parsed > 0:
    result = parsed

proc parseMultipartName(dispositionLine: string): string =
  ## Extracts form field name from Content-Disposition header line.
  let marker = "name=\""
  let i = dispositionLine.find(marker)
  if i < 0:
    return
  let startAt = i + marker.len
  let endAt = dispositionLine.find('"', startAt)
  if endAt <= startAt:
    return
  result = dispositionLine[startAt ..< endAt]

proc parseMultipartBody(body: string, contentType: string): seq[(string, string)] =
  ## Parses multipart/form-data body key/value pairs.
  let boundaryMarker = "boundary="
  let boundaryPos = contentType.find(boundaryMarker)
  if boundaryPos < 0:
    return
  var boundary = contentType[boundaryPos + boundaryMarker.len .. ^1].strip()
  if boundary.len >= 2 and boundary[0] == '"' and boundary[^1] == '"':
    boundary = boundary[1 .. ^2]
  let delimiter = "--" & boundary
  for rawPart in body.split(delimiter):
    var part = rawPart.strip(chars = {'\r', '\n'})
    if part.len == 0 or part == "--":
      continue
    if part.endsWith("--"):
      part = part[0 ..< part.len - 2].strip(chars = {'\r', '\n'})
    let splitAt = part.find("\r\n\r\n")
    if splitAt < 0:
      continue
    let headerText = part[0 ..< splitAt]
    var payload = part[splitAt + 4 .. ^1]
    if payload.endsWith("\r\n"):
      payload = payload[0 ..< payload.len - 2]
    var fieldName = ""
    for line in headerText.split("\r\n"):
      if line.toLowerAscii().startsWith("content-disposition:"):
        fieldName = parseMultipartName(line)
        break
    if fieldName.len > 0:
      result.add((fieldName, payload))

proc totalPages(totalItems: int, pageSize: int): int =
  ## Calculates page count for pagination.
  if totalItems <= 0:
    return 1
  (totalItems + pageSize - 1) div pageSize

proc parseFormBody(request: Request): seq[(string, string)] =
  ## Parses URL-encoded or multipart POST body key/value pairs.
  let contentType = request.headers["Content-Type"]
  if contentType.toLowerAscii().startsWith("multipart/form-data"):
    return parseMultipartBody(request.body, contentType)
  let parsed = parseUrl("?" & request.body)
  for (key, value) in parsed.query:
    result.add((key, value))

proc formValue(form: seq[(string, string)], key: string): string =
  ## Gets first value for a form key.
  for (k, v) in form:
    if k == key:
      return v

proc cleanTitle(value: string): string =
  ## Normalizes topic title.
  truncateUtf8(value.strip(), 180)

proc cleanBody(value: string): string =
  ## Normalizes post body.
  truncateUtf8(value.strip(), 12000)

proc hasMinPostLines(value: string, minLines = 4): bool =
  ## Ensures a post has at least the required count of non-empty lines.
  var lineCount = 0
  for line in value.splitLines():
    if line.strip().len > 0:
      inc lineCount
  lineCount >= minLines

proc cleanRouteUsername(value: string): string =
  ## Normalizes route username segment.
  value.strip()

proc htmlHeaders(): HttpHeaders =
  ## Builds headers for HTML responses.
  result["Content-Type"] = "text/html; charset=utf-8"

proc addSetCookie(headers: var HttpHeaders, setCookie: string) =
  ## Appends one Set-Cookie header without replacing others.
  if setCookie.len > 0:
    headers.toBase.add(("Set-Cookie", setCookie))

proc logHttpError(request: Request, statusCode: int) =
  ## Logs all HTTP error responses to stderr.
  if statusCode >= 400:
    stderr.writeLine("[http] ", statusCode, " ", request.uri)

proc logHttpAccess(request: Request, statusCode: int) =
  ## Logs all HTTP responses to stderr.
  stderr.writeLine("[access] ", statusCode, " ", request.uri)

proc logHttpResponse(request: Request, statusCode: int) =
  ## Logs page access and error responses.
  request.logHttpAccess(statusCode)
  request.logHttpError(statusCode)

proc logValidationFailure(routeName: string, request: Request, reason: string) =
  ## Logs non-exception validation rejections with context.
  stderr.writeLine("[validation] route=", routeName, " uri=", request.uri, " reason=", reason)

proc logHandlerException(routeName: string, request: Request, e: ref Exception) =
  ## Logs a handler exception with stack trace.
  stderr.writeLine("[exception] route=", routeName, " uri=", request.uri)
  stderr.writeLine("[exception] message=", e.msg)
  stderr.writeLine(getStackTrace(e))

proc csrfForRequest(request: Request): tuple[token: string, setCookie: string] =
  ## Returns CSRF token for this request and optional Set-Cookie value.
  let existing = request.csrfCookieValue()
  if existing.len > 0:
    return (existing, "")
  let token = makeCsrfToken()
  (token, makeCsrfSetCookie(token))

proc currentUsernameOf(user: AccountUser): string =
  ## Returns username text for templates and error pages.
  if user.isNil:
    return ""
  user.username

proc respondHtml(
  request: Request,
  statusCode: int,
  body: string,
  setCookies: seq[string] = @[]
) =
  ## Sends an HTML response with optional Set-Cookie headers.
  var headers = htmlHeaders()
  for setCookie in setCookies:
    headers.addSetCookie(setCookie)
  request.logHttpResponse(statusCode)
  request.respond(statusCode, headers, body)

proc respondErrorPage(
  request: Request,
  routeName: string,
  statusCode: int,
  message: string,
  currentUsername = "",
  csrfToken = "",
  setCookies: seq[string] = @[]
) =
  ## Logs and returns a rendered error page for all expected failures.
  logValidationFailure(routeName, request, message)
  let body = renderErrorPage(statusCode, message, currentUsername, csrfToken)
  request.respondHtml(statusCode, body, setCookies)

proc respondRedirect(
  request: Request,
  location: string,
  setCookies: seq[string] = @[]
) =
  ## Sends a redirect response with optional Set-Cookie headers.
  var headers = htmlHeaders()
  headers["Location"] = location
  for setCookie in setCookies:
    headers.addSetCookie(setCookie)
  request.logHttpResponse(302)
  request.respond(302, headers, "")

proc requireCsrf(
  request: Request,
  routeName: string,
  form: seq[(string, string)],
  currentUsername = ""
): bool =
  ## Validates double-submit CSRF and responds 403 on failure.
  let csrf = request.csrfForRequest()
  if csrfTokensMatch(request.csrfCookieValue(), form.formValue("csrf")):
    return true
  request.respondErrorPage(
    routeName,
    403,
    "Invalid CSRF token.",
    currentUsername,
    csrf.token,
    if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
  )
  false

proc respondInternalError(request: Request) =
  ## Sends a plain fallback 500 response without template rendering.
  let body = "<!doctype html><html><body><h1>Internal server error.</h1></body></html>"
  request.respondHtml(500, body)

proc respondCss(request: Request) =
  ## Serves the extracted forum stylesheet.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/css; charset=utf-8"
  request.logHttpResponse(200)
  request.respond(200, headers, ForumCss)

proc respondImage(request: Request) =
  ## Serves bundled SVG icon assets.
  let name = request.pathParams["name"]
  var body = ""
  case name
  of "forum-folder.svg":
    body = ForumFolderSvg
  of "forum-pin.svg":
    body = ForumPinSvg
  of "topic.svg":
    body = TopicSvg
  of "topic-hot.svg":
    body = TopicHotSvg
  of "topic-locked.svg":
    body = TopicLockedSvg
  else:
    request.logHttpResponse(404)
    request.respond(404, htmlHeaders(), "")
    return
  var headers: HttpHeaders
  headers["Content-Type"] = "image/svg+xml; charset=utf-8"
  request.logHttpResponse(200)
  request.respond(200, headers, body)

let pool = newForumPool("forum.db", 10)
pool.initSchema()
pool.initAccountsSchema()
pool.seedDefaultBoard()

proc indexHandler(request: Request) {.gcsafe.} =
  ## Handles board index route.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
    var rows: seq[BoardRow]
    for stats in pool.listBoardStats():
      rows.add(BoardRow(
        board: stats.board,
        topicCount: stats.topicCount,
        postCount: stats.postCount,
        lastPost: stats.lastPost
      ))
    let body = renderBoardIndex(
      rows,
      pool.countUsers(),
      currentUsername,
      csrf.token
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("indexHandler", request, e)
    request.respondInternalError()

proc boardHandler(request: Request) {.gcsafe.} =
  ## Handles board listing route.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
      board = pool.getBoardBySlug(request.pathParams["slug"])
    if board.isNil:
      request.respondErrorPage(
        "boardHandler",
        404,
        "Board not found.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let page = pageFromUri(request.uri)
    let topicCount = pool.countTopicsByBoard(board.id)
    let pages = totalPages(topicCount, PageSize)
    var rows: seq[TopicRow]
    for stats in pool.listTopicStatsByBoard(board.id, page, PageSize):
      rows.add(TopicRow(
        topic: stats.topic,
        replyCount: stats.replyCount,
        isHot: stats.isHot
      ))
    let body = renderBoardPage(
      board,
      rows,
      page,
      pages,
      currentUsername,
      csrf.token
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("boardHandler", request, e)
    request.respondInternalError()

proc topicHandler(request: Request) {.gcsafe.} =
  ## Handles topic page route.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
      topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      request.respondErrorPage(
        "topicHandler",
        400,
        "Bad topic id.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let topic = pool.getTopicById(topicId)
    if topic.isNil:
      request.respondErrorPage(
        "topicHandler",
        404,
        "Topic not found.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let page = pageFromUri(request.uri)
    let postCount = pool.countPostsByTopic(topic.id)
    let pages = totalPages(postCount, PageSize)
    let posts = pool.listPostsByTopic(topic.id, page, PageSize)
    var
      authorNames: seq[string]
      authorStatuses: seq[(string, string)]
    for post in posts:
      if post.authorName.len == 0:
        continue
      if post.authorName notin authorNames:
        authorNames.add(post.authorName)
    for authorName in authorNames:
      let user = pool.getUserByUsername(authorName)
      if user.isNil:
        continue
      authorStatuses.add((user.username, user.userStatus))
    let board = pool.getBoardById(topic.boardId)
    let isAdmin = not currentUser.isNil and currentUser.isAdmin
    let body = renderTopicPage(
      topic,
      posts,
      page,
      pages,
      currentUsername,
      if board.isNil: "" else: board.title,
      if board.isNil: "" else: board.slug,
      authorStatuses,
      csrf.token,
      isAdmin
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("topicHandler", request, e)
    request.respondInternalError()

proc newTopicHandler(request: Request) {.gcsafe.} =
  ## Handles create-topic form submission.
  try:
    let
      board = pool.getBoardBySlug(request.pathParams["slug"])
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
    if board.isNil:
      request.respondErrorPage(
        "newTopicHandler",
        404,
        "Board not found.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    if currentUser.isNil:
      request.respondErrorPage(
        "newTopicHandler",
        401,
        "You must be logged in to post.",
        "",
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let form = request.parseFormBody()
    if not request.requireCsrf("newTopicHandler", form, currentUsername):
      return
    let author = currentUser.username
    let title = cleanTitle(form.formValue("title"))
    let body = cleanBody(form.formValue("body"))
    if title.len == 0 or body.len == 0:
      request.respondErrorPage(
        "newTopicHandler",
        400,
        "Title and message are required.",
        currentUsername,
        csrf.token
      )
      return
    if not hasMinPostLines(body):
      request.respondErrorPage(
        "newTopicHandler",
        400,
        "Message must be at least 4 lines.",
        currentUsername,
        csrf.token
      )
      return
    let topic = pool.createTopicWithFirstPost(
      board.id,
      title,
      author,
      body,
      models.nowEpoch()
    )
    pool.incrementThreadAndPostCount(currentUser)
    request.respondRedirect("/t/" & $topic.id)
  except Exception as e:
    logHandlerException("newTopicHandler", request, e)
    request.respondInternalError()

proc replyHandler(request: Request) {.gcsafe.} =
  ## Handles create-reply form submission.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
      topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      request.respondErrorPage(
        "replyHandler",
        400,
        "Bad topic id.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let topic = pool.getTopicById(topicId)
    if topic.isNil:
      request.respondErrorPage(
        "replyHandler",
        404,
        "Topic not found.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    if topic.locked:
      request.respondErrorPage(
        "replyHandler",
        403,
        "This topic is locked.",
        currentUsername,
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    if currentUser.isNil:
      request.respondErrorPage(
        "replyHandler",
        401,
        "You must be logged in to post.",
        "",
        csrf.token,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let form = request.parseFormBody()
    if not request.requireCsrf("replyHandler", form, currentUsername):
      return
    let author = currentUser.username
    let body = cleanBody(form.formValue("body"))
    if body.len == 0:
      request.respondErrorPage(
        "replyHandler",
        400,
        "Reply message is required.",
        currentUsername,
        csrf.token
      )
      return
    if not hasMinPostLines(body):
      request.respondErrorPage(
        "replyHandler",
        400,
        "Reply must be at least 4 lines.",
        currentUsername,
        csrf.token
      )
      return
    discard pool.createReply(topicId, author, body, models.nowEpoch())
    pool.incrementPostCount(currentUser)
    let
      postCount = pool.countPostsByTopic(topicId)
      pages = totalPages(postCount, PageSize)
    if pages > 1:
      request.respondRedirect("/t/" & $topicId & "?page=" & $pages)
    else:
      request.respondRedirect("/t/" & $topicId)
  except Exception as e:
    logHandlerException("replyHandler", request, e)
    request.respondInternalError()

proc setTopicLockHandler(request: Request, locked: bool) {.gcsafe.} =
  ## Handles admin lock or unlock for one topic.
  let routeName =
    if locked:
      "lockTopicHandler"
    else:
      "unlockTopicHandler"
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
      topicId = parsePositiveInt(request.pathParams["id"])
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if topicId == 0:
      request.respondErrorPage(
        routeName,
        400,
        "Bad topic id.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let topic = pool.getTopicById(topicId)
    if topic.isNil:
      request.respondErrorPage(
        routeName,
        404,
        "Topic not found.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    if currentUser.isNil or not currentUser.isAdmin:
      request.respondErrorPage(
        routeName,
        403,
        "Admin access required.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let form = request.parseFormBody()
    if not request.requireCsrf(routeName, form, currentUsername):
      return
    pool.setTopicLocked(topic, locked)
    request.respondRedirect("/t/" & $topic.id)
  except Exception as e:
    logHandlerException(routeName, request, e)
    request.respondInternalError()

proc lockTopicHandler(request: Request) {.gcsafe.} =
  ## Locks one topic so replies are disabled.
  request.setTopicLockHandler(true)

proc unlockTopicHandler(request: Request) {.gcsafe.} =
  ## Unlocks one topic so replies are enabled.
  request.setTopicLockHandler(false)

proc registerPageHandler(request: Request) {.gcsafe.} =
  ## Handles register page GET.
  try:
    let csrf = request.csrfForRequest()
    let body = renderRegisterPage(csrfToken = csrf.token)
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("registerPageHandler", request, e)
    request.respondInternalError()

proc registerSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles register page POST.
  try:
    let
      csrf = request.csrfForRequest()
      form = request.parseFormBody()
      username = cleanUsername(form.formValue("username"))
      email = cleanEmail(form.formValue("email"))
      password = form.formValue("password")
      repeatPassword = form.formValue("repeatPassword")
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if username.len < UsernameMinLen or email.len < 3 or password.len < 6:
      logValidationFailure("registerSubmitHandler", request, "username/email/password are too short")
      let invalidForm = renderRegisterPage(
        "Username/email/password are too short.",
        username,
        email,
        csrf.token
      )
      request.respondHtml(400, invalidForm, csrfCookies)
      return
    if not isValidUsername(username):
      logValidationFailure("registerSubmitHandler", request, "username has invalid characters")
      let invalidName = renderRegisterPage(
        "Username must be 3-30 ASCII letters, digits, _ or -.",
        username,
        email,
        csrf.token
      )
      request.respondHtml(400, invalidName, csrfCookies)
      return
    if password != repeatPassword:
      logValidationFailure("registerSubmitHandler", request, "passwords do not match")
      let mismatch = renderRegisterPage(
        "Passwords do not match.",
        username,
        email,
        csrf.token
      )
      request.respondHtml(400, mismatch, csrfCookies)
      return
    var user: AccountUser
    try:
      user = pool.createUser(serverSecret(), username, email, password)
    except Exception as e:
      if not isUniqueConstraintError(e):
        raise
      if not pool.getUserByUsername(username).isNil or
        "username" in e.msg.toLowerAscii():
        logValidationFailure("registerSubmitHandler", request, "username is already taken")
        let duplicateName = renderRegisterPage(
          "Username is already taken.",
          username,
          email,
          csrf.token
        )
        request.respondHtml(400, duplicateName, csrfCookies)
        return
      logValidationFailure("registerSubmitHandler", request, "email is already registered")
      let duplicateEmail = renderRegisterPage(
        "Email is already registered.",
        username,
        email,
        csrf.token
      )
      request.respondHtml(400, duplicateEmail, csrfCookies)
      return
    let session = pool.createSession(user.id)
    var cookies = @[makeSessionSetCookie(session.token)]
    if csrf.setCookie.len > 0:
      cookies.add(csrf.setCookie)
    request.respondRedirect("/", cookies)
  except Exception as e:
    logHandlerException("registerSubmitHandler", request, e)
    request.respondInternalError()

proc loginPageHandler(request: Request) {.gcsafe.} =
  ## Handles login page GET.
  try:
    let csrf = request.csrfForRequest()
    let body = renderLoginPage(csrfToken = csrf.token)
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("loginPageHandler", request, e)
    request.respondInternalError()

proc loginSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles login page POST.
  try:
    let
      csrf = request.csrfForRequest()
      form = request.parseFormBody()
      username = cleanUsername(form.formValue("username"))
      password = form.formValue("password")
      user = pool.authenticateUser(serverSecret(), username, password)
    if user.isNil:
      logValidationFailure("loginSubmitHandler", request, "invalid username or password")
      let badLogin = renderLoginPage(
        "Invalid username or password.",
        username,
        csrf.token
      )
      request.respondHtml(
        401,
        badLogin,
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
      )
      return
    let session = pool.createSession(user.id)
    var cookies = @[makeSessionSetCookie(session.token)]
    if csrf.setCookie.len > 0:
      cookies.add(csrf.setCookie)
    request.respondRedirect("/", cookies)
  except Exception as e:
    logHandlerException("loginSubmitHandler", request, e)
    request.respondInternalError()

proc logoutGetHandler(request: Request) {.gcsafe.} =
  ## Rejects GET logout to prevent CSRF logout via links.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      csrf = request.csrfForRequest()
    request.respondErrorPage(
      "logoutGetHandler",
      405,
      "Use POST to logout.",
      currentUsernameOf(currentUser),
      csrf.token,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("logoutGetHandler", request, e)
    request.respondInternalError()

proc logoutHandler(request: Request) {.gcsafe.} =
  ## Handles logout POST.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      form = request.parseFormBody()
    if not request.requireCsrf("logoutHandler", form, currentUsername):
      return
    let token = request.sessionCookieValue()
    pool.clearSession(token)
    request.respondRedirect("/", @[makeClearSessionCookie(), makeClearCsrfCookie()])
  except Exception as e:
    logHandlerException("logoutHandler", request, e)
    request.respondInternalError()

proc forgotPasswordPageHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-password page GET.
  try:
    let csrf = request.csrfForRequest()
    let body = renderForgotPasswordPage(csrfToken = csrf.token)
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("forgotPasswordPageHandler", request, e)
    request.respondInternalError()

proc forgotPasswordSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-password page POST.
  try:
    let
      csrf = request.csrfForRequest()
      form = request.parseFormBody()
      email = cleanEmail(form.formValue("email"))
      user = pool.getUserByEmail(email)
    if not user.isNil:
      let reset = pool.createPasswordResetToken(user.id)
      stderr.writeLine("[mail] To: ", user.email)
      stderr.writeLine("[mail] Subject: Reset your Nobby password")
      stderr.writeLine("[mail] Body: Visit http://localhost:8080/reset-password?token=", reset.token)
    let body = renderForgotPasswordPage(
      "If that email exists, a reset message was sent.",
      email,
      csrf.token
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("forgotPasswordSubmitHandler", request, e)
    request.respondInternalError()

proc resetPasswordPageHandler(request: Request) {.gcsafe.} =
  ## Handles reset-password page GET.
  try:
    let
      csrf = request.csrfForRequest()
      token = parseUrl(request.uri).query["token"]
      body = renderResetPasswordPage(token, csrfToken = csrf.token)
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("resetPasswordPageHandler", request, e)
    request.respondInternalError()

proc resetPasswordSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles reset-password page POST.
  try:
    let
      csrf = request.csrfForRequest()
      form = request.parseFormBody()
      token = form.formValue("token")
      password = form.formValue("password")
      repeatPassword = form.formValue("repeatPassword")
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if password.len < 6:
      logValidationFailure("resetPasswordSubmitHandler", request, "password is too short")
      let weak = renderResetPasswordPage(
        token,
        "Password is too short.",
        csrf.token
      )
      request.respondHtml(400, weak, csrfCookies)
      return
    if password != repeatPassword:
      logValidationFailure("resetPasswordSubmitHandler", request, "passwords do not match")
      let mismatch = renderResetPasswordPage(
        token,
        "Passwords do not match.",
        csrf.token
      )
      request.respondHtml(400, mismatch, csrfCookies)
      return
    let reset = pool.consumePasswordResetToken(token)
    if reset.isNil:
      logValidationFailure("resetPasswordSubmitHandler", request, "reset token is invalid or expired")
      let invalidToken = renderResetPasswordPage(
        token,
        "Reset token is invalid or expired.",
        csrf.token
      )
      request.respondHtml(400, invalidToken, csrfCookies)
      return
    let user = pool.getUserById(reset.userId)
    if user.isNil:
      request.respondErrorPage(
        "resetPasswordSubmitHandler",
        404,
        "Account was not found.",
        "",
        csrf.token,
        csrfCookies
      )
      return
    pool.setUserPassword(serverSecret(), user, password)
    let session = pool.createSession(user.id)
    var cookies = @[makeSessionSetCookie(session.token)]
    if csrf.setCookie.len > 0:
      cookies.add(csrf.setCookie)
    request.respondRedirect("/", cookies)
  except Exception as e:
    logHandlerException("resetPasswordSubmitHandler", request, e)
    request.respondInternalError()

proc forgotUsernamePageHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-username page GET.
  try:
    let csrf = request.csrfForRequest()
    let body = renderForgotUsernamePage(csrfToken = csrf.token)
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("forgotUsernamePageHandler", request, e)
    request.respondInternalError()

proc forgotUsernameSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-username page POST.
  try:
    let
      csrf = request.csrfForRequest()
      form = request.parseFormBody()
      email = cleanEmail(form.formValue("email"))
      user = pool.getUserByEmail(email)
    if not user.isNil:
      stderr.writeLine("[mail] To: ", user.email)
      stderr.writeLine("[mail] Subject: Your Nobby username")
      stderr.writeLine("[mail] Body: Your username is ", user.username)
    let body = renderForgotUsernamePage(
      "If that email exists, a username reminder was sent.",
      email,
      csrf.token
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("forgotUsernameSubmitHandler", request, e)
    request.respondInternalError()

proc usersPageHandler(request: Request) {.gcsafe.} =
  ## Handles users page GET.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      isAdmin = not currentUser.isNil and currentUser.isAdmin
      csrf = request.csrfForRequest()
      requestedPage = pageFromUri(request.uri)
      userCount = pool.countUsers()
      pageCount = totalPages(userCount, PageSize)
    var page = requestedPage
    if page > pageCount:
      page = pageCount
    let rows = pool.listUserStats(page, PageSize)
    let body = renderUsersPage(
      rows,
      isAdmin,
      currentUsername,
      isAdmin,
      page,
      pageCount,
      csrf.token
    )
    request.respondHtml(
      200,
      body,
      if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    )
  except Exception as e:
    logHandlerException("usersPageHandler", request, e)
    request.respondInternalError()

proc userPageHandler(request: Request) {.gcsafe.} =
  ## Handles one user profile page GET.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      isAdmin = not currentUser.isNil and currentUser.isAdmin
      csrf = request.csrfForRequest()
      routeUsername = cleanRouteUsername(request.pathParams["username"])
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if routeUsername.len == 0:
      request.respondErrorPage(
        "userPageHandler",
        400,
        "Bad username.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let user = pool.getUserByUsername(routeUsername)
    if user.isNil:
      request.respondErrorPage(
        "userPageHandler",
        404,
        "User not found.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let canEdit = not currentUser.isNil and currentUser.id == user.id
    let body = renderUserPage(
      user,
      currentUsername,
      isAdmin,
      canEdit,
      csrf.token
    )
    request.respondHtml(200, body, csrfCookies)
  except Exception as e:
    logHandlerException("userPageHandler", request, e)
    request.respondInternalError()

proc editUserPageHandler(request: Request) {.gcsafe.} =
  ## Handles profile edit page GET.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      isAdmin = not currentUser.isNil and currentUser.isAdmin
      csrf = request.csrfForRequest()
      routeUsername = cleanRouteUsername(request.pathParams["username"])
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if currentUser.isNil:
      request.respondErrorPage(
        "editUserPageHandler",
        401,
        "You must be logged in to edit your profile.",
        "",
        csrf.token,
        csrfCookies
      )
      return
    if currentUser.username != routeUsername:
      request.respondErrorPage(
        "editUserPageHandler",
        403,
        "You can only edit your own profile.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let body = renderEditUserPage(
      currentUser,
      "",
      currentUsername,
      isAdmin,
      csrf.token
    )
    request.respondHtml(200, body, csrfCookies)
  except Exception as e:
    logHandlerException("editUserPageHandler", request, e)
    request.respondInternalError()

proc editUserSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles profile edit page POST.
  try:
    let
      currentUser = pool.getCurrentUser(request)
      currentUsername = currentUsernameOf(currentUser)
      csrf = request.csrfForRequest()
      routeUsername = cleanRouteUsername(request.pathParams["username"])
      csrfCookies =
        if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
    if currentUser.isNil:
      request.respondErrorPage(
        "editUserSubmitHandler",
        401,
        "You must be logged in to edit your profile.",
        "",
        csrf.token,
        csrfCookies
      )
      return
    if currentUser.username != routeUsername:
      request.respondErrorPage(
        "editUserSubmitHandler",
        403,
        "You can only edit your own profile.",
        currentUsername,
        csrf.token,
        csrfCookies
      )
      return
    let form = request.parseFormBody()
    if not request.requireCsrf("editUserSubmitHandler", form, currentUsername):
      return
    pool.updateUserProfile(
      currentUser,
      form.formValue("userStatus"),
      form.formValue("userBio")
    )
    request.respondRedirect("/u/" & currentUser.username)
  except Exception as e:
    logHandlerException("editUserSubmitHandler", request, e)
    request.respondInternalError()

var router: Router
router.get("/style.css", respondCss)
router.get("/images/@name", respondImage)
router.get("/", indexHandler)
router.get("/register", registerPageHandler)
router.post("/register", registerSubmitHandler)
router.get("/login", loginPageHandler)
router.post("/login", loginSubmitHandler)
router.get("/logout", logoutGetHandler)
router.post("/logout", logoutHandler)
router.get("/forgot-password", forgotPasswordPageHandler)
router.post("/forgot-password", forgotPasswordSubmitHandler)
router.get("/reset-password", resetPasswordPageHandler)
router.post("/reset-password", resetPasswordSubmitHandler)
router.get("/forgot-username", forgotUsernamePageHandler)
router.post("/forgot-username", forgotUsernameSubmitHandler)
router.get("/users", usersPageHandler)
router.get("/u/@username", userPageHandler)
router.get("/u/@username/edit", editUserPageHandler)
router.post("/u/@username/edit", editUserSubmitHandler)
router.get("/b/@slug", boardHandler)
router.get("/t/@id", topicHandler)
router.post("/b/@slug/new", newTopicHandler)
router.post("/t/@id/reply", replyHandler)
router.post("/t/@id/lock", lockTopicHandler)
router.post("/t/@id/unlock", unlockTopicHandler)

router.notFoundHandler = proc(request: Request) {.gcsafe.} =
  let
    currentUser = pool.getCurrentUser(request)
    csrf = request.csrfForRequest()
  request.respondErrorPage(
    "notFoundHandler",
    404,
    "Page not found.",
    currentUsernameOf(currentUser),
    csrf.token,
    if csrf.setCookie.len > 0: @[csrf.setCookie] else: @[]
  )

let server = newServer(router)
echo "Serving forum on http://localhost:8080"
server.serve(Port(8080))
