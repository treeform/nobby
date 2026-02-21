import
  std/strutils,
  chrono,
  markdown,
  taggy,
  models,
  utils

type
  BoardRow* = object
    board*: Board
    topicCount*: int
    postCount*: int
    lastPost*: BoardLastPost

  TopicRow* = object
    topic*: Topic
    replyCount*: int

proc fmtEpoch(ts: int64): string =
  ## Formats Unix timestamp for page output.
  Timestamp(ts.float64).format("{year/4}-{month/2}-{day/2} {hour/2}:{minute/2}:{second/2} UTC")

proc renderPostMarkdown(text: string): string =
  ## Converts post markdown to HTML using GFM parsing.
  markdown(
    text,
    config = initGfmConfig(
      escape = true,
      keepHtml = false
    )
  )

proc sectionName(board: Board): string =
  ## Returns normalized section title for one board.
  result = board.section.strip()
  if result.len == 0:
    return "General Discussions"

proc renderErrorPage*(statusCode: int, message: string, currentUsername = ""): string =
  ## Renders basic error page.
  let content = renderFragment:
    table ".grid":
      tr:
        td ".toprow":
          say "Error " & $statusCode
      tr:
        td ".row2":
          p ".mediumtext":
            say esc(message)
          p ".smalltext":
            a:
              href "/"
              say "Back to boards"
  renderLayout("Error", content, currentUsername, @[("Index", "/"), ("Error", "")])

proc renderBoardIndex*(rows: seq[BoardRow], userCount = 0, currentUsername = ""): string =
  ## Renders board index page.
  type
    SectionGroup = object
      title: string
      rows: seq[BoardRow]
  var
    totalTopics = 0
    totalPosts = 0
    sectionGroups: seq[SectionGroup]
  for row in rows:
    totalTopics += row.topicCount
    totalPosts += row.postCount
    let title = sectionName(row.board)
    if sectionGroups.len == 0 or sectionGroups[^1].title != title:
      sectionGroups.add(SectionGroup(title: title))
    sectionGroups[^1].rows.add(row)
  let content = renderFragment:
    section "#index.section":
      table ".lineup":
        tr:
          td:
            span ".largetext":
              b:
                say "Index"
          td ".right.smalltext":
            say "Boards: " & $rows.len & " | Topics: " & $totalTopics & " | Posts: " & $totalPosts & " | Users: "
            a ".topiclink":
              href "/users"
              say $userCount
      table ".grid":
        tr:
          td ".toprow center":
            say " "
          td ".toprow":
            b:
              say "Forum"
          td ".toprow center foldable":
            b:
              say "Topics"
          td ".toprow center foldable":
            b:
              say "Posts"
          td ".toprow":
            b:
              say "Last Post"
        for sectionGroup in sectionGroups:
          tr:
            td ".catrow":
              colspan "5"
              b:
                say sectionGroup.title
          for row in sectionGroup.rows:
            tr:
              td ".row1 iconcell":
                img ".forum-icon":
                  src "/images/forum-folder.svg"
                  alt "Forum icon"
              td ".row2":
                a ".topiclink forumlink":
                  href "/b/" & row.board.slug
                  say esc(row.board.title)
                p ".smalltext":
                  say esc(row.board.description)
              td ".row1 center foldable mediumtext":
                say $row.topicCount
              td ".row2 center foldable mediumtext":
                say $row.postCount
              td ".row1 right smalltext":
                if row.lastPost.topicId > 0:
                  say fmtEpoch(row.lastPost.createdAt)
                  say " by "
                  a ".topiclink":
                    href "/u/" & row.lastPost.authorName
                    say esc(row.lastPost.authorName)
                else:
                  say "No posts yet"
  renderLayout("Index", content, currentUsername)

proc renderNewTopicForm(board: Board): string =
  ## Renders create-topic form.
  renderFragment:
    section "#compose.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Create new topic"
        tr:
          td ".row2":
            form ".post-form":
              action "/b/" & board.slug & "/new"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "new-topic-title"
                  say "Title"
                input "#new-topic-title":
                  ttype "text"
                  name "title"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "new-topic-body"
                  say "Message"
                textarea "#new-topic-body":
                  name "body"
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Post topic"

proc renderLoginRequired(actionLabel: string): string =
  ## Renders a simple login-required message block.
  renderFragment:
    section "#compose.section":
      table ".grid":
        tr:
          td ".toprow":
            say actionLabel
        tr:
          td ".row2":
            p ".smalltext":
              say "You must be logged in to post."
            p ".smalltext":
              a:
                href "/login"
                say "Login"
              say " | "
              a:
                href "/register"
                say "Register"

proc renderBoardPage*(
  board: Board,
  rows: seq[TopicRow],
  page: int,
  pages: int,
  currentUsername = ""
): string =
  ## Renders topic listing for one board.
  let
    basePath = "/b/" & board.slug
    pagination = renderPagination(basePath, page, pages)
    newTopicForm =
      if currentUsername.len > 0:
        renderNewTopicForm(board)
      else:
        renderLoginRequired("Create new topic")
  let content = renderFragment:
    section "#listing.section":
      say pagination
      table ".grid":
        tr:
          td ".toprow center":
            say " "
          td ".toprow":
            say "Thread"
          td ".toprow center foldable":
            say "Starter"
          td ".toprow center foldable":
            say "Replies"
          td ".toprow":
            say "Last Post"
        for row in rows:
          tr:
            td ".row1 iconcell":
              img ".forum-icon":
                src "/images/topic.svg"
                alt "Topic icon"
            td ".row2":
              a ".topiclink":
                href "/t/" & $row.topic.id
                say esc(row.topic.title)
            td ".row1 center foldable":
              a ".topiclink":
                href "/u/" & row.topic.authorName
                say esc(row.topic.authorName)
            td ".row2 center foldable":
              say $row.replyCount
            td ".row1":
              say fmtEpoch(row.topic.updatedAt)
      say pagination
      say newTopicForm
  renderLayout(
    board.title,
    content,
    currentUsername,
    @[("Index", "/"), (board.title, "")]
  )

proc renderReplyForm(topic: Topic): string =
  ## Renders reply form for a topic.
  renderFragment:
    section "#compose.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Reply"
        tr:
          td ".row2":
            form ".post-form":
              action "/t/" & $topic.id & "/reply"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "reply-body"
                  say "Message"
                textarea "#reply-body":
                  name "body"
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Post reply"

proc renderTopicPage*(
  topic: Topic,
  posts: seq[Post],
  page: int,
  pages: int,
  currentUsername = "",
  boardTitle = "",
  boardSlug = "",
  authorStatuses: seq[(string, string)] = @[]
): string =
  ## Renders topic and replies page.
  proc statusForAuthor(authorName: string): string =
    ## Finds one user status by author name.
    for (name, status) in authorStatuses:
      if name == authorName:
        return status
  let
    basePath = "/t/" & $topic.id
    pagination = renderPagination(basePath, page, pages)
    replyForm =
      if currentUsername.len > 0:
        renderReplyForm(topic)
      else:
        renderLoginRequired("Reply")
  let content = renderFragment:
    section "#post.section":
      say pagination
      table ".grid post-layout":
        tr:
          td ".toprow authorcol":
            say "Author"
          td ".toprow":
            say "Post"
          td ".toprow":
            say "Posted"
        for post in posts:
          tr:
            td ".row1 authorcol":
              a ".topiclink":
                href "/u/" & post.authorName
                say esc(post.authorName)
              let status = statusForAuthor(post.authorName)
              if status.len > 0:
                p ".smalltext":
                  say esc(status)
            td ".row2 postbody":
              say renderPostMarkdown(post.body)
            td ".row1":
              say fmtEpoch(post.createdAt)
      say pagination
      say replyForm
  var breadcrumb = @[("Index", "/")]
  if boardTitle.len > 0:
    let boardLink =
      if boardSlug.len > 0: "/b/" & boardSlug
      else: ""
    breadcrumb.add((boardTitle, boardLink))
  breadcrumb.add((topic.title, ""))
  renderLayout(topic.title, content, currentUsername, breadcrumb)
