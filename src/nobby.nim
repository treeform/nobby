import
  std/[strutils, uri],
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
  ## Reads optional page query from URI.
  result = 1
  let queryStart = rawUri.find('?')
  if queryStart < 0 or queryStart >= rawUri.len - 1:
    return
  let queryPart = rawUri[queryStart + 1 .. ^1]
  for (key, value) in decodeQuery(queryPart, '&'):
    if key == "page":
      let parsed = parsePositiveInt(value)
      if parsed > 0:
        result = parsed
      return

proc totalPages(totalItems: int, pageSize: int): int =
  ## Calculates page count for pagination.
  if totalItems <= 0:
    return 1
  (totalItems + pageSize - 1) div pageSize

proc parseFormBody(request: Request): seq[(string, string)] =
  ## Parses URL-encoded POST body key/value pairs.
  for (key, value) in decodeQuery(request.body, '&'):
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

proc respondHtml(request: Request, statusCode: int, body: string) =
  ## Sends an HTML response.
  request.respond(statusCode, htmlHeaders(), body)

proc respondRedirect(request: Request, location: string) =
  ## Sends a simple redirect response.
  var headers = htmlHeaders()
  headers["Location"] = location
  request.respond(302, headers, "")

proc respondCss(request: Request) =
  ## Serves the extracted forum stylesheet.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/css; charset=utf-8"
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
    request.respond(404, htmlHeaders(), "")
    return
  var headers: HttpHeaders
  headers["Content-Type"] = "image/svg+xml; charset=utf-8"
  request.respond(200, headers, body)
let pool = newForumPool("forum.db", 10)
pool.initSchema()
pool.seedDefaultBoard()

proc indexHandler(request: Request) {.gcsafe.} =
  ## Handles board index route.
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

proc boardHandler(request: Request) {.gcsafe.} =
  ## Handles board listing route.
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

proc topicHandler(request: Request) {.gcsafe.} =
  ## Handles topic page route.
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

proc newTopicHandler(request: Request) {.gcsafe.} =
  ## Handles create-topic form submission.
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

proc replyHandler(request: Request) {.gcsafe.} =
  ## Handles create-reply form submission.
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

var router: Router
router.get("/style.css", respondCss)
router.get("/images/@name", respondImage)
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
