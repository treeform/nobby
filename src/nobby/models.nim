import
  std/[os, strutils, times],
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
    locked*: bool
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

  BoardStats* = object
    board*: Board
    topicCount*: int
    postCount*: int
    lastPost*: BoardLastPost

  TopicStats* = object
    topic*: Topic
    replyCount*: int
    recentPostCount*: int
    isHot*: bool

  CountRow = ref object
    count: int

  BoardStatsRow = ref object
    id: int
    section: string
    slug: string
    title: string
    description: string
    createdAt: int64
    topicCount: int
    postCount: int
    lastCreatedAt: int64
    lastAuthorName: string
    lastTopicId: int
    lastTopicTitle: string

  TopicStatsRow = ref object
    id: int
    boardId: int
    title: string
    authorName: string
    locked: bool
    createdAt: int64
    updatedAt: int64
    postCount: int
    recentPostCount: int

const
  HotWindowSeconds* = 60 * 60 * 24
  HotRecentPostMin* = 5

proc nowEpoch*(): int64 =
  ## Returns current Unix timestamp.
  getTime().toUnix()

proc topicIsHot*(locked: bool, recentPostCount: int): bool =
  ## Returns true when a topic should show the hot icon.
  not locked and recentPostCount >= HotRecentPostMin

proc countValue(rows: seq[CountRow]): int =
  ## Returns the first count value from a COUNT query.
  if rows.len > 0:
    return rows[0].count

proc configureSqlite*(db: Db) =
  ## Enables WAL and a busy timeout for concurrent writers.
  discard db.query("PRAGMA journal_mode = WAL")
  discard db.query("PRAGMA busy_timeout = 5000")
  discard db.query("PRAGMA synchronous = NORMAL")

const
  BusyRetryAttempts = 5
  BusyRetryBaseMs = 15

proc isBusyLockError*(e: ref Exception): bool =
  ## Returns true when an exception looks like a transient SQLite lock.
  let msg = e.msg.toLowerAscii()
  "database is locked" in msg or
    "database is busy" in msg or
    "sqlite_busy" in msg or
    "sqlite_locked" in msg

template withBusyRetry*(body: untyped) =
  ## Retries a DB write a few times on transient SQLite lock errors.
  block:
    var attempt = 0
    while true:
      inc attempt
      try:
        body
        break
      except DbError as e:
        if not isBusyLockError(e) or attempt >= BusyRetryAttempts:
          raise
        sleep(BusyRetryBaseMs * attempt)

proc newForumPool*(dbPath = "forum.db", poolSize = 10): Pool =
  ## Creates a DB pool for forum requests.
  result = newPool()
  for i in 0 ..< poolSize:
    let db = openDatabase(dbPath)
    configureSqlite(db)
    result.add(db)

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
    let topicColumns = db.query("PRAGMA table_info(topic)")
    var hasLocked = false
    for topicColumn in topicColumns:
      if topicColumn.len > 1 and topicColumn[1] == "locked":
        hasLocked = true
        break
    if not hasLocked:
      discard db.query(
        "ALTER TABLE topic ADD COLUMN locked INTEGER NOT NULL DEFAULT 0"
      )
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
  let boards = pool.filter(Board, it.slug == slug)
  if boards.len > 0:
    return boards[0]

proc getBoardById*(pool: Pool, boardId: int): Board =
  ## Finds board by numeric id.
  let boards = pool.filter(Board, it.id == boardId)
  if boards.len > 0:
    return boards[0]

proc countTopicsByBoard*(pool: Pool, boardId: int): int =
  ## Counts topics in a board.
  countValue(pool.query(
    CountRow,
    "SELECT COUNT(*) AS count FROM topic WHERE board_id = ?",
    boardId
  ))

proc listBoardStats*(pool: Pool): seq[BoardStats] =
  ## Lists boards with topic/post counts and last post in one query.
  let rows = pool.query(
    BoardStatsRow,
    """
    SELECT
      b.id AS id,
      b.section AS section,
      b.slug AS slug,
      b.title AS title,
      b.description AS description,
      b.created_at AS created_at,
      COALESCE(tc.cnt, 0) AS topic_count,
      COALESCE(pc.cnt, 0) AS post_count,
      COALESCE(lp.created_at, 0) AS last_created_at,
      COALESCE(lp.author_name, '') AS last_author_name,
      COALESCE(lp.topic_id, 0) AS last_topic_id,
      COALESCE(lp.topic_title, '') AS last_topic_title
    FROM board b
    LEFT JOIN (
      SELECT board_id, COUNT(*) AS cnt
      FROM topic
      GROUP BY board_id
    ) tc ON tc.board_id = b.id
    LEFT JOIN (
      SELECT t.board_id, COUNT(*) AS cnt
      FROM post p
      JOIN topic t ON p.topic_id = t.id
      GROUP BY t.board_id
    ) pc ON pc.board_id = b.id
    LEFT JOIN (
      SELECT
        t.board_id,
        p.created_at,
        p.author_name,
        t.id AS topic_id,
        t.title AS topic_title
      FROM post p
      JOIN topic t ON p.topic_id = t.id
      JOIN (
        SELECT t2.board_id, MAX(p2.id) AS max_post_id
        FROM post p2
        JOIN topic t2 ON p2.topic_id = t2.id
        GROUP BY t2.board_id
      ) latest ON latest.max_post_id = p.id
    ) lp ON lp.board_id = b.id
    ORDER BY b.section ASC, b.created_at ASC, b.id ASC
    """
  )
  for row in rows:
    var lastPost: BoardLastPost
    if row.lastTopicId > 0:
      lastPost.createdAt = row.lastCreatedAt
      lastPost.authorName = row.lastAuthorName
      lastPost.topicId = row.lastTopicId
      lastPost.topicTitle = row.lastTopicTitle
    result.add(BoardStats(
      board: Board(
        id: row.id,
        section: row.section,
        slug: row.slug,
        title: row.title,
        description: row.description,
        createdAt: row.createdAt
      ),
      topicCount: row.topicCount,
      postCount: row.postCount,
      lastPost: lastPost
    ))

proc listTopicStatsByBoard*(
  pool: Pool,
  boardId: int,
  page = 1,
  pageSize = 30
): seq[TopicStats] =
  ## Lists paged topics with reply and recent-activity counts.
  let
    safePage = max(1, page)
    safePageSize = max(1, pageSize)
    offset = (safePage - 1) * safePageSize
    recentAfter = nowEpoch() - HotWindowSeconds.int64
  let rows = pool.query(
    TopicStatsRow,
    """
    SELECT
      t.id AS id,
      t.board_id AS board_id,
      t.title AS title,
      t.author_name AS author_name,
      t.locked AS locked,
      t.created_at AS created_at,
      t.updated_at AS updated_at,
      COALESCE((
        SELECT COUNT(*) FROM post p WHERE p.topic_id = t.id
      ), 0) AS post_count,
      COALESCE((
        SELECT COUNT(*) FROM post p
        WHERE p.topic_id = t.id AND p.created_at >= ?
      ), 0) AS recent_post_count
    FROM topic t
    WHERE t.board_id = ?
    ORDER BY t.updated_at DESC, t.id DESC
    LIMIT ? OFFSET ?
    """,
    recentAfter,
    boardId,
    safePageSize,
    offset
  )
  for row in rows:
    result.add(TopicStats(
      topic: Topic(
        id: row.id,
        boardId: row.boardId,
        title: row.title,
        authorName: row.authorName,
        locked: row.locked,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
      ),
      replyCount: max(0, row.postCount - 1),
      recentPostCount: row.recentPostCount,
      isHot: topicIsHot(row.locked, row.recentPostCount)
    ))

proc getTopicById*(pool: Pool, topicId: int): Topic =
  ## Finds topic by id.
  pool.get(Topic, topicId)

proc setTopicLocked*(pool: Pool, topic: Topic, locked: bool) =
  ## Sets whether a topic accepts new replies.
  if topic.isNil:
    return
  topic.locked = locked
  withBusyRetry:
    pool.update(topic)

proc countPostsByTopic*(pool: Pool, topicId: int): int =
  ## Counts posts in a topic.
  countValue(pool.query(
    CountRow,
    "SELECT COUNT(*) AS count FROM post WHERE topic_id = ?",
    topicId
  ))

proc listPostsByTopic*(
  pool: Pool,
  topicId: int,
  page = 1,
  pageSize = 30
): seq[Post] =
  ## Lists paged posts sorted oldest first.
  let
    safePage = max(1, page)
    safePageSize = max(1, pageSize)
    offset = (safePage - 1) * safePageSize
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
  withBusyRetry:
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
  withBusyRetry:
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
