import
  std/[os, strutils],
  webby,
  mummy, mummy/routers,
  nobby/[accounts, models, pages]
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
  except:
    result = 0

proc serverSecret(): string =
  ## Loads server password pepper from environment.
  getEnv("NOBBY_SERVER_SECRET", "nobby-dev-secret-change-me")

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

proc cleanAuthor(value: string): string =
  ## Normalizes author name and falls back to Anonymous.
  result = value.strip()
  if result.len == 0:
    return "Anonymous"
  if result.len > 60:
    result = result[0 .. 59]

proc cleanTitle(value: string): string =
  ## Normalizes topic title.
  result = value.strip()
  if result.len > 180:
    result = result[0 .. 179]

proc cleanBody(value: string): string =
  ## Normalizes post body.
  result = value.strip()
  if result.len > 12000:
    result = result[0 .. 11999]

proc htmlHeaders(): HttpHeaders =
  ## Builds headers for HTML responses.
  result["Content-Type"] = "text/html; charset=utf-8"

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

proc respondHtml(request: Request, statusCode: int, body: string) =
  ## Sends an HTML response.
  request.logHttpResponse(statusCode)
  request.respond(statusCode, htmlHeaders(), body)

proc respondErrorPage(
  request: Request,
  routeName: string,
  statusCode: int,
  message: string,
  currentUsername = ""
) =
  ## Logs and returns a rendered error page for all expected failures.
  logValidationFailure(routeName, request, message)
  let body = renderErrorPage(statusCode, message, currentUsername)
  request.respondHtml(statusCode, body)

proc respondRedirect(request: Request, location: string) =
  ## Sends a simple redirect response.
  var headers = htmlHeaders()
  headers["Location"] = location
  request.logHttpResponse(302)
  request.respond(302, headers, "")

proc respondRedirectWithCookie(request: Request, location: string, setCookie: string) =
  ## Sends redirect and one Set-Cookie header.
  var headers = htmlHeaders()
  headers["Location"] = location
  headers["Set-Cookie"] = setCookie
  request.logHttpResponse(302)
  request.respond(302, headers, "")

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

proc quitHandler(request: Request) {.gcsafe.} =
  ## Stops the server process for local testing workflows.
  request.logHttpResponse(200)
  request.respond(200, htmlHeaders(), "Shutting down.")
  quit(0)
let pool = newForumPool("forum.db", 10)
pool.initSchema()
pool.initAccountsSchema()
pool.seedDefaultBoard()

proc indexHandler(request: Request) {.gcsafe.} =
  ## Handles board index route.
  try:
    let currentUser = pool.getCurrentUser(request)
    var rows: seq[BoardRow]
    for board in pool.listBoards():
      rows.add(BoardRow(
        board: board,
        topicCount: pool.countTopicsByBoard(board.id),
        postCount: pool.countPostsByBoard(board.id),
        lastPost: pool.getLastPostByBoard(board.id)
      ))
    let body = renderBoardIndex(rows, if currentUser.isNil: "" else: currentUser.username)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("indexHandler", request, e)
    request.respondInternalError()

proc boardHandler(request: Request) {.gcsafe.} =
  ## Handles board listing route.
  try:
    let currentUser = pool.getCurrentUser(request)
    let board = pool.getBoardBySlug(request.pathParams["slug"])
    if board.isNil:
      request.respondErrorPage(
        "boardHandler",
        404,
        "Board not found.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    let page = pageFromUri(request.uri)
    let topicCount = pool.countTopicsByBoard(board.id)
    let pages = totalPages(topicCount, PageSize)
    var rows: seq[TopicRow]
    for topic in pool.listTopicsByBoard(board.id, page, PageSize):
      let replies = max(0, pool.countPostsByTopic(topic.id) - 1)
      rows.add(TopicRow(topic: topic, replyCount: replies))
    let body = renderBoardPage(board, rows, page, pages, if currentUser.isNil: "" else: currentUser.username)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("boardHandler", request, e)
    request.respondInternalError()

proc topicHandler(request: Request) {.gcsafe.} =
  ## Handles topic page route.
  try:
    let currentUser = pool.getCurrentUser(request)
    let topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      request.respondErrorPage(
        "topicHandler",
        400,
        "Bad topic id.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    let topic = pool.getTopicById(topicId)
    if topic.isNil:
      request.respondErrorPage(
        "topicHandler",
        404,
        "Topic not found.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    let page = pageFromUri(request.uri)
    let postCount = pool.countPostsByTopic(topic.id)
    let pages = totalPages(postCount, PageSize)
    let posts = pool.listPostsByTopic(topic.id, page, PageSize)
    let board = pool.getBoardById(topic.boardId)
    let body = renderTopicPage(
      topic,
      posts,
      page,
      pages,
      if currentUser.isNil: "" else: currentUser.username,
      if board.isNil: "" else: board.title,
      if board.isNil: "" else: board.slug
    )
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("topicHandler", request, e)
    request.respondInternalError()

proc newTopicHandler(request: Request) {.gcsafe.} =
  ## Handles create-topic form submission.
  try:
    let board = pool.getBoardBySlug(request.pathParams["slug"])
    let currentUser = pool.getCurrentUser(request)
    if board.isNil:
      request.respondErrorPage(
        "newTopicHandler",
        404,
        "Board not found.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    if currentUser.isNil:
      request.respondErrorPage("newTopicHandler", 401, "You must be logged in to post.")
      return
    let form = request.parseFormBody()
    let author = currentUser.username
    let title = cleanTitle(form.formValue("title"))
    let body = cleanBody(form.formValue("body"))
    if title.len == 0 or body.len == 0:
      request.respondErrorPage("newTopicHandler", 400, "Title and message are required.")
      return
    let topic = pool.createTopicWithFirstPost(
      board.id,
      title,
      author,
      body,
      models.nowEpoch()
    )
    request.respondRedirect("/t/" & $topic.id)
  except Exception as e:
    logHandlerException("newTopicHandler", request, e)
    request.respondInternalError()

proc replyHandler(request: Request) {.gcsafe.} =
  ## Handles create-reply form submission.
  try:
    let currentUser = pool.getCurrentUser(request)
    let topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      request.respondErrorPage(
        "replyHandler",
        400,
        "Bad topic id.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    if pool.getTopicById(topicId).isNil:
      request.respondErrorPage(
        "replyHandler",
        404,
        "Topic not found.",
        if currentUser.isNil: "" else: currentUser.username
      )
      return
    if currentUser.isNil:
      request.respondErrorPage("replyHandler", 401, "You must be logged in to post.")
      return
    let form = request.parseFormBody()
    let author = currentUser.username
    let body = cleanBody(form.formValue("body"))
    if body.len == 0:
      request.respondErrorPage("replyHandler", 400, "Reply message is required.")
      return
    discard pool.createReply(topicId, author, body, models.nowEpoch())
    request.respondRedirect("/t/" & $topicId)
  except Exception as e:
    logHandlerException("replyHandler", request, e)
    request.respondInternalError()

proc registerPageHandler(request: Request) {.gcsafe.} =
  ## Handles register page GET.
  try:
    let body = renderRegisterPage()
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("registerPageHandler", request, e)
    request.respondInternalError()

proc registerSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles register page POST.
  try:
    let form = request.parseFormBody()
    let username = cleanUsername(form.formValue("username"))
    let email = cleanEmail(form.formValue("email"))
    let password = form.formValue("password")
    let repeatPassword = form.formValue("repeatPassword")
    if username.len < 3 or email.len < 3 or password.len < 6:
      logValidationFailure("registerSubmitHandler", request, "username/email/password are too short")
      let invalidForm = renderRegisterPage("Username/email/password are too short.", username, email)
      request.respondHtml(400, invalidForm)
      return
    if password != repeatPassword:
      logValidationFailure("registerSubmitHandler", request, "passwords do not match")
      let mismatch = renderRegisterPage("Passwords do not match.", username, email)
      request.respondHtml(400, mismatch)
      return
    if not pool.getUserByUsername(username).isNil:
      logValidationFailure("registerSubmitHandler", request, "username is already taken")
      let duplicateName = renderRegisterPage("Username is already taken.", username, email)
      request.respondHtml(400, duplicateName)
      return
    if not pool.getUserByEmail(email).isNil:
      logValidationFailure("registerSubmitHandler", request, "email is already registered")
      let duplicateEmail = renderRegisterPage("Email is already registered.", username, email)
      request.respondHtml(400, duplicateEmail)
      return
    let user = pool.createUser(serverSecret(), username, email, password)
    let session = pool.createSession(user.id)
    request.respondRedirectWithCookie("/", makeSessionSetCookie(session.token))
  except Exception as e:
    logHandlerException("registerSubmitHandler", request, e)
    request.respondInternalError()

proc loginPageHandler(request: Request) {.gcsafe.} =
  ## Handles login page GET.
  try:
    let body = renderLoginPage()
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("loginPageHandler", request, e)
    request.respondInternalError()

proc loginSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles login page POST.
  try:
    let form = request.parseFormBody()
    let username = cleanUsername(form.formValue("username"))
    let password = form.formValue("password")
    let user = pool.authenticateUser(serverSecret(), username, password)
    if user.isNil:
      logValidationFailure("loginSubmitHandler", request, "invalid username or password")
      let badLogin = renderLoginPage("Invalid username or password.", username)
      request.respondHtml(401, badLogin)
      return
    let session = pool.createSession(user.id)
    request.respondRedirectWithCookie("/", makeSessionSetCookie(session.token))
  except Exception as e:
    logHandlerException("loginSubmitHandler", request, e)
    request.respondInternalError()

proc logoutHandler(request: Request) {.gcsafe.} =
  ## Handles logout POST.
  try:
    let token = request.sessionCookieValue()
    pool.clearSession(token)
    request.respondRedirectWithCookie("/", makeClearSessionCookie())
  except Exception as e:
    logHandlerException("logoutHandler", request, e)
    request.respondInternalError()

proc forgotPasswordPageHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-password page GET.
  try:
    let body = renderForgotPasswordPage()
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("forgotPasswordPageHandler", request, e)
    request.respondInternalError()

proc forgotPasswordSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-password page POST.
  try:
    let form = request.parseFormBody()
    let email = cleanEmail(form.formValue("email"))
    let user = pool.getUserByEmail(email)
    if not user.isNil:
      let reset = pool.createPasswordResetToken(user.id)
      stderr.writeLine("[mail] To: ", user.email)
      stderr.writeLine("[mail] Subject: Reset your Nobby password")
      stderr.writeLine("[mail] Body: Visit http://localhost:8080/reset-password?token=", reset.token)
    let body = renderForgotPasswordPage(
      "If that email exists, a reset message was sent.",
      email
    )
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("forgotPasswordSubmitHandler", request, e)
    request.respondInternalError()

proc resetPasswordPageHandler(request: Request) {.gcsafe.} =
  ## Handles reset-password page GET.
  try:
    let token = parseUrl(request.uri).query["token"]
    let body = renderResetPasswordPage(token)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("resetPasswordPageHandler", request, e)
    request.respondInternalError()

proc resetPasswordSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles reset-password page POST.
  try:
    let form = request.parseFormBody()
    let token = form.formValue("token")
    let password = form.formValue("password")
    let repeatPassword = form.formValue("repeatPassword")
    if password.len < 6:
      logValidationFailure("resetPasswordSubmitHandler", request, "password is too short")
      let weak = renderResetPasswordPage(token, "Password is too short.")
      request.respondHtml(400, weak)
      return
    if password != repeatPassword:
      logValidationFailure("resetPasswordSubmitHandler", request, "passwords do not match")
      let mismatch = renderResetPasswordPage(token, "Passwords do not match.")
      request.respondHtml(400, mismatch)
      return
    let reset = pool.consumePasswordResetToken(token)
    if reset.isNil:
      logValidationFailure("resetPasswordSubmitHandler", request, "reset token is invalid or expired")
      let invalidToken = renderResetPasswordPage(token, "Reset token is invalid or expired.")
      request.respondHtml(400, invalidToken)
      return
    let user = pool.getUserById(reset.userId)
    if user.isNil:
      request.respondErrorPage("resetPasswordSubmitHandler", 404, "Account was not found.")
      return
    pool.setUserPassword(serverSecret(), user, password)
    let session = pool.createSession(user.id)
    request.respondRedirectWithCookie("/", makeSessionSetCookie(session.token))
  except Exception as e:
    logHandlerException("resetPasswordSubmitHandler", request, e)
    request.respondInternalError()

proc forgotUsernamePageHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-username page GET.
  try:
    let body = renderForgotUsernamePage()
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("forgotUsernamePageHandler", request, e)
    request.respondInternalError()

proc forgotUsernameSubmitHandler(request: Request) {.gcsafe.} =
  ## Handles forgot-username page POST.
  try:
    let form = request.parseFormBody()
    let email = cleanEmail(form.formValue("email"))
    let user = pool.getUserByEmail(email)
    if not user.isNil:
      stderr.writeLine("[mail] To: ", user.email)
      stderr.writeLine("[mail] Subject: Your Nobby username")
      stderr.writeLine("[mail] Body: Your username is ", user.username)
    let body = renderForgotUsernamePage(
      "If that email exists, a username reminder was sent.",
      email
    )
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("forgotUsernameSubmitHandler", request, e)
    request.respondInternalError()

var router: Router
router.get("/style.css", respondCss)
router.get("/images/@name", respondImage)
router.get("/quit", quitHandler)
router.get("/", indexHandler)
router.get("/register", registerPageHandler)
router.post("/register", registerSubmitHandler)
router.get("/login", loginPageHandler)
router.post("/login", loginSubmitHandler)
router.post("/logout", logoutHandler)
router.get("/forgot-password", forgotPasswordPageHandler)
router.post("/forgot-password", forgotPasswordSubmitHandler)
router.get("/reset-password", resetPasswordPageHandler)
router.post("/reset-password", resetPasswordSubmitHandler)
router.get("/forgot-username", forgotUsernamePageHandler)
router.post("/forgot-username", forgotUsernameSubmitHandler)
router.get("/b/@slug", boardHandler)
router.get("/t/@id", topicHandler)
router.post("/b/@slug/new", newTopicHandler)
router.post("/t/@id/reply", replyHandler)

router.notFoundHandler = proc(request: Request) {.gcsafe.} =
  let currentUser = pool.getCurrentUser(request)
  request.respondErrorPage(
    "notFoundHandler",
    404,
    "Page not found.",
    if currentUser.isNil: "" else: currentUser.username
  )

let server = newServer(router)
echo "Serving forum on http://localhost:8080"
server.serve(Port(8080))
