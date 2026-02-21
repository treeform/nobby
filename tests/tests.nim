import
  std/[os, osproc, streams, strutils, times],
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

proc postMultipartForm(client: Curly, path: string, data: seq[(string, string)]): Response =
  ## Posts multipart/form-data and returns response.
  var entries: seq[MultipartEntry]
  for (key, value) in data:
    entries.add(MultipartEntry(name: key, payload: value))
  let (contentType, body) = encodeMultipart(entries)
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  client.post(BaseUrl & path, headers, body)

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

  let boardPath = firstHrefPath(indexHtml, "/b/")
  doAssert boardPath.len > 0, "Could not find a board link on index page."

  echo "Testing board page."
  let boardHtml = curl.get(BaseUrl & boardPath).body
  doAssert "Thread" in boardHtml, "Board thread column missing."
  doAssert "Create new topic" in boardHtml, "Board create-topic form missing."

  echo "Testing topic creation."
  let createdTitle = "E2E topic title"
  let createdBody = "E2E topic body for verification."
  let topicCreate = postMultipartForm(curl, boardPath & "/new", @[
    ("author", "E2EUser"),
    ("title", createdTitle),
    ("body", createdBody)
  ])
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

  echo "Testing reply submission."
  let replyBody = "E2E reply body verification."
  let replyCreate = postForm(curl, topicPath & "/reply", @[
    ("author", "E2EReplyUser"),
    ("body", replyBody)
  ])
  doAssert replyCreate.code in [200, 302, 405], "Expected success, redirect, or redirect-follow method mismatch after reply submission."

  echo "Testing reply visibility."
  let topicAfterReply = curl.get(BaseUrl & topicPath).body
  doAssert replyBody in topicAfterReply, "Reply body not visible after posting."

  echo "All integration checks passed."

when isMainModule:
  main()
