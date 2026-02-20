import
  std/[strutils, times],
  taggy,
  models

const
  AppTitle* = "Nobby, a bulletin board style forum"
  AppTagline* = "Visual forum inspired by the early 2000s message boards."

type
  BoardRow* = object
    board*: Board
    topicCount*: int
    postCount*: int
    lastPost*: BoardLastPost

  TopicRow* = object
    topic*: Topic
    replyCount*: int

proc esc(text: string): string =
  ## Escapes HTML special characters.
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc fmtEpoch(ts: int64): string =
  ## Formats Unix timestamp for page output.
  fromUnix(ts).utc.format("yyyy-MM-dd HH:mm:ss 'UTC'")

proc sectionName(board: Board): string =
  ## Returns normalized section title for one board.
  result = board.section.strip()
  if result.len == 0:
    return "General Discussions"

proc renderPagination(basePath: string, page: int, pages: int): string =
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

proc renderLayout(pageTitle: string, content: string): string =
  ## Renders page shell and shared navigation.
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
          p ".smalltext":
            span ".maintitle":
              say AppTitle
          p ".smalltext":
            say AppTagline
          p ".navigation":
            a:
              href "/"
              say "Index"
            a:
              href "#listing"
              say "Listing"
            a:
              href "#post"
              say "Post"
            a:
              href "#compose"
              say "Posting Form"
          say content
          p ".footer-note":
            say AppTagline

proc renderErrorPage*(statusCode: int, message: string): string =
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
  renderLayout("Error", content)

proc renderBoardIndex*(rows: seq[BoardRow]): string =
  ## Renders board index page.
  type
    SectionGroup = object
      title: string
      rows: seq[BoardRow]
  var totalTopics = 0
  var totalPosts = 0
  var sectionGroups: seq[SectionGroup]
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
            span ".crumb.smalltext":
              say "Root > Forums"
          td ".right.smalltext":
            say "Boards: " & $rows.len & " | Topics: " & $totalTopics & " | Posts: " & $totalPosts
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
                    href "/t/" & $row.lastPost.topicId
                    say esc(row.lastPost.authorName)
                else:
                  say "No posts yet"
  renderLayout("Index", content)

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
                  tfor "new-topic-author"
                  say "Name"
                input "#new-topic-author":
                  ttype "text"
                  name "author"
                  value "Anonymous"
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

proc renderBoardPage*(
  board: Board,
  rows: seq[TopicRow],
  page: int,
  pages: int
): string =
  ## Renders topic listing for one board.
  let basePath = "/b/" & board.slug
  let content = renderFragment:
    section "#listing.section":
      p ".largetext":
        b:
          say esc(board.title)
      p ".meta":
        say esc(board.description)
      say renderPagination(basePath, page, pages)
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
              say esc(row.topic.authorName)
            td ".row2 center foldable":
              say $row.replyCount
            td ".row1":
              say fmtEpoch(row.topic.updatedAt)
      say renderPagination(basePath, page, pages)
      say renderNewTopicForm(board)
  renderLayout(board.title, content)

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
                  tfor "reply-author"
                  say "Name"
                input "#reply-author":
                  ttype "text"
                  name "author"
                  value "Anonymous"
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
  pages: int
): string =
  ## Renders topic and replies page.
  let basePath = "/t/" & $topic.id
  let content = renderFragment:
    section "#post.section":
      p ".largetext":
        b:
          say esc(topic.title)
      p ".meta":
        say "Started by " & esc(topic.authorName) & " at " & fmtEpoch(topic.createdAt)
      say renderPagination(basePath, page, pages)
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
              say esc(post.authorName)
            td ".row2 postbody":
              say esc(post.body)
            td ".row1":
              say fmtEpoch(post.createdAt)
      say renderPagination(basePath, page, pages)
      say renderReplyForm(topic)
  renderLayout(topic.title, content)
