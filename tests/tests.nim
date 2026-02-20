import
  std/[httpclient, os, osproc, strutils, times, uri]

const
  BaseUrl = "http://127.0.0.1:8080"

proc waitForServer(client: HttpClient, timeoutMs = 8000) =
  ## Waits until the local forum server responds.
  let started = epochTime()
  while true:
    try:
      discard client.getContent(BaseUrl & "/")
      return
    except:
      if int((epochTime() - started) * 1000) > timeoutMs:
        doAssert false, "Server did not start on http://127.0.0.1:8080 in time."
      sleep(150)

proc ensurePortIsFree() =
  ## Ensures no process already serves on port 8080.
  let probe = newHttpClient(timeout = 300)
  try:
    discard probe.getContent(BaseUrl & "/")
    doAssert false, "Port 8080 is already in use. Stop running nobby server before tests."
  except:
    discard
  finally:
    probe.close()

proc compileServer(repoRoot: string) =
  ## Compiles the nobby server executable.
  let command = "nim c " & quoteShell(repoRoot / "src" / "nobby.nim")
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

proc postForm(client: HttpClient, path: string, data: seq[(string, string)]): Response =
  ## Posts x-www-form-urlencoded data and returns response.
  let body = encodeQuery(data)
  let headers = newHttpHeaders({
    "Content-Type": "application/x-www-form-urlencoded"
  })
  client.request(
    BaseUrl & path,
    httpMethod = HttpPost,
    headers = headers,
    body = body
  )

proc main() =
  ## Runs an integration smoke test against key forum flows.
  let repoRoot = getCurrentDir()
  ensurePortIsFree()
  compileServer(repoRoot)

  let serverExe =
    when defined(windows):
      repoRoot / "src" / "nobby.exe"
    else:
      repoRoot / "src" / "nobby"
  doAssert fileExists(serverExe), "Server executable not found at " & serverExe

  let tempRoot = repoRoot / "tests" / ".tmp-e2e"
  if dirExists(tempRoot):
    removeDir(tempRoot)
  createDir(tempRoot)

  var server = startProcess(
    command = serverExe,
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

  let client = newHttpClient(timeout = 3000, maxRedirects = 0)
  defer:
    client.close()

  waitForServer(client)

  echo "Testing index page."
  let indexHtml = client.getContent(BaseUrl & "/")
  doAssert "Index" in indexHtml, "Index page heading missing."
  doAssert "Topics" in indexHtml, "Index topics column missing."
  doAssert "Posts" in indexHtml, "Index posts column missing."
  doAssert "Last Post" in indexHtml, "Index last-post column missing."
  doAssert "General Discussions" in indexHtml, "Index section header missing."

  let boardPath = firstHrefPath(indexHtml, "/b/")
  doAssert boardPath.len > 0, "Could not find a board link on index page."

  echo "Testing board page."
  let boardHtml = client.getContent(BaseUrl & boardPath)
  doAssert "Thread" in boardHtml, "Board thread column missing."
  doAssert "Create new topic" in boardHtml, "Board create-topic form missing."

  echo "Testing topic creation."
  let createdTitle = "E2E topic title"
  let createdBody = "E2E topic body for verification."
  let topicCreate = postForm(client, boardPath & "/new", @[
    ("author", "E2EUser"),
    ("title", createdTitle),
    ("body", createdBody)
  ])
  doAssert topicCreate.code == Http302, "Expected redirect after creating topic."
  let topicPath = topicCreate.headers.getOrDefault("Location")
  doAssert topicPath.startsWith("/t/"), "Missing topic redirect location."

  echo "Testing topic page."
  let topicHtml = client.getContent(BaseUrl & topicPath)
  doAssert createdTitle in topicHtml, "Created topic title not found."
  doAssert createdBody in topicHtml, "Created topic body not found."

  echo "Testing reply submission."
  let replyBody = "E2E reply body verification."
  let replyCreate = postForm(client, topicPath & "/reply", @[
    ("author", "E2EReplyUser"),
    ("body", replyBody)
  ])
  doAssert replyCreate.code == Http302, "Expected redirect after reply submission."

  echo "Testing reply visibility."
  let topicAfterReply = client.getContent(BaseUrl & topicPath)
  doAssert replyBody in topicAfterReply, "Reply body not visible after posting."

  echo "All integration checks passed."

when isMainModule:
  main()
