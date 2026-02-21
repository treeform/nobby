import
  std/strutils,
  webby,
  mummy, mummy/routers,
  nobby/[models, pages]
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

proc logHandlerException(routeName: string, request: Request, e: ref Exception) =
  ## Logs a handler exception with stack trace.
  stderr.writeLine("[exception] route=", routeName, " uri=", request.uri)
  stderr.writeLine("[exception] message=", e.msg)
  stderr.writeLine(getStackTrace(e))

proc respondHtml(request: Request, statusCode: int, body: string) =
  ## Sends an HTML response.
  request.logHttpResponse(statusCode)
  request.respond(statusCode, htmlHeaders(), body)

proc respondRedirect(request: Request, location: string) =
  ## Sends a simple redirect response.
  var headers = htmlHeaders()
  headers["Location"] = location
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
pool.seedDefaultBoard()

proc indexHandler(request: Request) {.gcsafe.} =
  ## Handles board index route.
  try:
    var rows: seq[BoardRow]
    for board in pool.listBoards():
      rows.add(BoardRow(
        board: board,
        topicCount: pool.countTopicsByBoard(board.id),
        postCount: pool.countPostsByBoard(board.id),
        lastPost: pool.getLastPostByBoard(board.id)
      ))
    var body = ""
    {.cast(gcsafe).}:
      body = renderBoardIndex(rows)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("indexHandler", request, e)
    request.respondInternalError()

proc boardHandler(request: Request) {.gcsafe.} =
  ## Handles board listing route.
  try:
    let board = pool.getBoardBySlug(request.pathParams["slug"])
    if board.isNil:
      var missingBoard = ""
      {.cast(gcsafe).}:
        missingBoard = renderErrorPage(404, "Board not found.")
      request.respondHtml(404, missingBoard)
      return
    let page = pageFromUri(request.uri)
    let topicCount = pool.countTopicsByBoard(board.id)
    let pages = totalPages(topicCount, PageSize)
    var rows: seq[TopicRow]
    for topic in pool.listTopicsByBoard(board.id, page, PageSize):
      let replies = max(0, pool.countPostsByTopic(topic.id) - 1)
      rows.add(TopicRow(topic: topic, replyCount: replies))
    var body = ""
    {.cast(gcsafe).}:
      body = renderBoardPage(board, rows, page, pages)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("boardHandler", request, e)
    request.respondInternalError()

proc topicHandler(request: Request) {.gcsafe.} =
  ## Handles topic page route.
  try:
    let topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      var badTopicId = ""
      {.cast(gcsafe).}:
        badTopicId = renderErrorPage(400, "Bad topic id.")
      request.respondHtml(400, badTopicId)
      return
    let topic = pool.getTopicById(topicId)
    if topic.isNil:
      var missingTopic = ""
      {.cast(gcsafe).}:
        missingTopic = renderErrorPage(404, "Topic not found.")
      request.respondHtml(404, missingTopic)
      return
    let page = pageFromUri(request.uri)
    let postCount = pool.countPostsByTopic(topic.id)
    let pages = totalPages(postCount, PageSize)
    let posts = pool.listPostsByTopic(topic.id, page, PageSize)
    var body = ""
    {.cast(gcsafe).}:
      body = renderTopicPage(topic, posts, page, pages)
    request.respondHtml(200, body)
  except Exception as e:
    logHandlerException("topicHandler", request, e)
    request.respondInternalError()

proc newTopicHandler(request: Request) {.gcsafe.} =
  ## Handles create-topic form submission.
  try:
    let board = pool.getBoardBySlug(request.pathParams["slug"])
    if board.isNil:
      var missingBoard = ""
      {.cast(gcsafe).}:
        missingBoard = renderErrorPage(404, "Board not found.")
      request.respondHtml(404, missingBoard)
      return
    let form = request.parseFormBody()
    let author = cleanAuthor(form.formValue("author"))
    let title = cleanTitle(form.formValue("title"))
    let body = cleanBody(form.formValue("body"))
    if title.len == 0 or body.len == 0:
      var invalidTopic = ""
      {.cast(gcsafe).}:
        invalidTopic = renderErrorPage(400, "Title and message are required.")
      request.respondHtml(400, invalidTopic)
      return
    let topic = pool.createTopicWithFirstPost(
      board.id,
      title,
      author,
      body,
      nowEpoch()
    )
    request.respondRedirect("/t/" & $topic.id)
  except Exception as e:
    logHandlerException("newTopicHandler", request, e)
    request.respondInternalError()

proc replyHandler(request: Request) {.gcsafe.} =
  ## Handles create-reply form submission.
  try:
    let topicId = parsePositiveInt(request.pathParams["id"])
    if topicId == 0:
      var badTopicId = ""
      {.cast(gcsafe).}:
        badTopicId = renderErrorPage(400, "Bad topic id.")
      request.respondHtml(400, badTopicId)
      return
    if pool.getTopicById(topicId).isNil:
      var missingTopic = ""
      {.cast(gcsafe).}:
        missingTopic = renderErrorPage(404, "Topic not found.")
      request.respondHtml(404, missingTopic)
      return
    let form = request.parseFormBody()
    let author = cleanAuthor(form.formValue("author"))
    let body = cleanBody(form.formValue("body"))
    if body.len == 0:
      var invalidReply = ""
      {.cast(gcsafe).}:
        invalidReply = renderErrorPage(400, "Reply message is required.")
      request.respondHtml(400, invalidReply)
      return
    discard pool.createReply(topicId, author, body, nowEpoch())
    request.respondRedirect("/t/" & $topicId)
  except Exception as e:
    logHandlerException("replyHandler", request, e)
    request.respondInternalError()

var router: Router
router.get("/style.css", respondCss)
router.get("/images/@name", respondImage)
router.get("/quit", quitHandler)
router.get("/", indexHandler)
router.get("/b/@slug", boardHandler)
router.get("/t/@id", topicHandler)
router.post("/b/@slug/new", newTopicHandler)
router.post("/t/@id/reply", replyHandler)

router.notFoundHandler = proc(request: Request) {.gcsafe.} =
  var missingPage = ""
  {.cast(gcsafe).}:
    missingPage = renderErrorPage(404, "Page not found.")
  request.respondHtml(404, missingPage)

let server = newServer(router)
echo "Serving forum on http://localhost:8080"
server.serve(Port(8080))
