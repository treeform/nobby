import
  std/[strutils, times],
  debby/[pools, sqlite]

type
  Board* = ref object
    id*: int
    section*: string
    slug*: string
    title*: string
    description*: string
    createdAt*: int64

  Topic* = ref object
    id*: int
    boardId*: int
    title*: string
    authorName*: string
    createdAt*: int64
    updatedAt*: int64

  Post* = ref object
    id*: int
    topicId*: int
    authorName*: string
    body*: string
    createdAt*: int64
  BoardLastPost* = object
    topicId*: int
    topicTitle*: string
    authorName*: string
    createdAt*: int64

proc nowEpoch*(): int64 =
  ## Returns current Unix timestamp.
  getTime().toUnix()

proc newForumPool*(dbPath = "forum.db", poolSize = 10): Pool =
  ## Creates a DB pool for forum requests.
  result = newPool()
  for i in 0 ..< poolSize:
    result.add(openDatabase(dbPath))

proc initSchema*(pool: Pool) =
  ## Creates forum tables and indexes if needed.
  pool.withDb:
    if not db.tableExists(Board):
      db.createTable(Board)
    let boardColumns = db.query("PRAGMA table_info(board)")
    var hasSection = false
    for boardColumn in boardColumns:
      if boardColumn.len > 1 and boardColumn[1] == "section":
        hasSection = true
        break
    if not hasSection:
      discard db.query("ALTER TABLE board ADD COLUMN section TEXT NOT NULL DEFAULT 'General Discussions'")
    db.checkTable(Board)
    db.createIndexIfNotExists(Board, "slug")
    if not db.tableExists(Topic):
      db.createTable(Topic)
    db.checkTable(Topic)
    db.createIndexIfNotExists(Topic, "boardId")
    db.createIndexIfNotExists(Topic, "updatedAt")
    if not db.tableExists(Post):
      db.createTable(Post)
    db.checkTable(Post)
    db.createIndexIfNotExists(Post, "topicId")
    db.createIndexIfNotExists(Post, "createdAt")

proc seedDefaultBoard*(pool: Pool) =
  ## Adds one default board when database is empty.
  if pool.filter(Board).len == 0:
    var board = Board(
      section: "General Discussions",
      slug: "main",
      title: "Main",
      description: "General discussion board.",
      createdAt: nowEpoch()
    )
    pool.insert(board)

proc listBoards*(pool: Pool): seq[Board] =
  ## Lists all boards by creation order.
  pool.query(
    Board,
    "SELECT * FROM board ORDER BY section ASC, created_at ASC, id ASC"
  )

proc getBoardBySlug*(pool: Pool, slug: string): Board =
  ## Finds board by slug.
  let boards = pool.query(
    Board,
    "SELECT * FROM board WHERE slug = ? LIMIT 1",
    slug
  )
  if boards.len > 0:
    return boards[0]

proc countTopicsByBoard*(pool: Pool, boardId: int): int =
  ## Counts topics in a board.
  let rows = pool.query(
    "SELECT COUNT(*) FROM topic WHERE board_id = ?",
    boardId
  )
  if rows.len > 0 and rows[0].len > 0:
    return rows[0][0].parseInt()
proc countPostsByBoard*(pool: Pool, boardId: int): int =
  ## Counts all posts in all topics for one board.
  let rows = pool.query(
    "SELECT COUNT(*) FROM post p JOIN topic t ON p.topic_id = t.id WHERE t.board_id = ?",
    boardId
  )
  if rows.len > 0 and rows[0].len > 0:
    return rows[0][0].parseInt()
proc getLastPostByBoard*(pool: Pool, boardId: int): BoardLastPost =
  ## Returns latest post metadata for one board.
  let rows = pool.query(
    "SELECT p.created_at, p.author_name, t.id, t.title FROM post p JOIN topic t ON p.topic_id = t.id WHERE t.board_id = ? ORDER BY p.created_at DESC, p.id DESC LIMIT 1",
    boardId
  )
  if rows.len == 0 or rows[0].len < 4:
    return
  result.createdAt = rows[0][0].parseBiggestInt().int64
  result.authorName = rows[0][1]
  result.topicId = rows[0][2].parseInt()
  result.topicTitle = rows[0][3]

proc listTopicsByBoard*(
  pool: Pool,
  boardId: int,
  page = 1,
  pageSize = 30
): seq[Topic] =
  ## Lists paged topics sorted by latest activity.
  let safePage = max(1, page)
  let safePageSize = max(1, pageSize)
  let offset = (safePage - 1) * safePageSize
  pool.query(
    Topic,
    "SELECT * FROM topic WHERE board_id = ? ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?",
    boardId,
    safePageSize,
    offset
  )

proc getTopicById*(pool: Pool, topicId: int): Topic =
  ## Finds topic by id.
  pool.get(Topic, topicId)

proc countPostsByTopic*(pool: Pool, topicId: int): int =
  ## Counts posts in a topic.
  let rows = pool.query(
    "SELECT COUNT(*) FROM post WHERE topic_id = ?",
    topicId
  )
  if rows.len > 0 and rows[0].len > 0:
    return rows[0][0].parseInt()

proc listPostsByTopic*(
  pool: Pool,
  topicId: int,
  page = 1,
  pageSize = 30
): seq[Post] =
  ## Lists paged posts sorted oldest first.
  let safePage = max(1, page)
  let safePageSize = max(1, pageSize)
  let offset = (safePage - 1) * safePageSize
  pool.query(
    Post,
    "SELECT * FROM post WHERE topic_id = ? ORDER BY created_at ASC, id ASC LIMIT ? OFFSET ?",
    topicId,
    safePageSize,
    offset
  )

proc createTopicWithFirstPost*(
  pool: Pool,
  boardId: int,
  title: string,
  authorName: string,
  body: string,
  createdAt: int64
): Topic =
  ## Creates topic and first post in one transaction.
  pool.withDb:
    db.withTransaction:
      result = Topic(
        boardId: boardId,
        title: title,
        authorName: authorName,
        createdAt: createdAt,
        updatedAt: createdAt
      )
      db.insert(result)
      var post = Post(
        topicId: result.id,
        authorName: authorName,
        body: body,
        createdAt: createdAt
      )
      db.insert(post)

proc createReply*(
  pool: Pool,
  topicId: int,
  authorName: string,
  body: string,
  createdAt: int64
): Post =
  ## Creates a reply and bumps topic updated time.
  pool.withDb:
    var topic = db.get(Topic, topicId)
    if topic.isNil:
      return nil
    db.withTransaction:
      result = Post(
        topicId: topicId,
        authorName: authorName,
        body: body,
        createdAt: createdAt
      )
      db.insert(result)
      topic.updatedAt = createdAt
      db.update(topic)
