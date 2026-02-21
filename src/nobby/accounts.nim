import
  std/[random, strutils],
  markdown,
  crunchy/sha256,
  debby/[pools, sqlite],
  mummy,
  taggy,
  models,
  utils

const
  DefaultPasswordIterations* = 120_000
  SaltBytes = 16
  TokenBytes = 24

var
  rngInit {.threadvar.}: bool

proc nowEpoch*(): int64
proc syncUserCounters*(pool: Pool)

type
  AccountUser* = ref object
    id*: int
    username*: string
    email*: string
    isAdmin*: bool
    threadCount*: int
    postCount*: int
    userStatus*: string
    userBio*: string
    passwordSalt*: string
    passwordHash*: string
    passwordIterations*: int
    createdAt*: int64
    updatedAt*: int64

  UserSession* = ref object
    id*: int
    userId*: int
    token*: string
    expiresAt*: int64
    createdAt*: int64

  PasswordResetToken* = ref object
    id*: int
    userId*: int
    token*: string
    expiresAt*: int64
    usedAt*: int64
    createdAt*: int64

proc initAccountsSchema*(pool: Pool) =
  ## Creates account-related tables and indexes if needed.
  pool.withDb:
    if not db.tableExists(AccountUser):
      db.createTable(AccountUser)
    let userColumns = db.query("PRAGMA table_info(account_user)")
    var
      hasIsAdmin = false
      hasThreadCount = false
      hasPostCount = false
      hasUserStatus = false
      hasUserBio = false
    for userColumn in userColumns:
      if userColumn.len > 1 and userColumn[1] == "is_admin":
        hasIsAdmin = true
      if userColumn.len > 1 and userColumn[1] == "thread_count":
        hasThreadCount = true
      if userColumn.len > 1 and userColumn[1] == "post_count":
        hasPostCount = true
      if userColumn.len > 1 and userColumn[1] == "user_status":
        hasUserStatus = true
      if userColumn.len > 1 and userColumn[1] == "user_bio":
        hasUserBio = true
    if not hasIsAdmin:
      discard db.query("ALTER TABLE account_user ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")
    if not hasThreadCount:
      discard db.query("ALTER TABLE account_user ADD COLUMN thread_count INTEGER NOT NULL DEFAULT 0")
    if not hasPostCount:
      discard db.query("ALTER TABLE account_user ADD COLUMN post_count INTEGER NOT NULL DEFAULT 0")
    if not hasUserStatus:
      discard db.query("ALTER TABLE account_user ADD COLUMN user_status TEXT NOT NULL DEFAULT ''")
    if not hasUserBio:
      discard db.query("ALTER TABLE account_user ADD COLUMN user_bio TEXT NOT NULL DEFAULT ''")
    db.checkTable(AccountUser)
    db.createIndexIfNotExists(AccountUser, "username")
    db.createIndexIfNotExists(AccountUser, "email")

    if not db.tableExists(UserSession):
      db.createTable(UserSession)
    db.checkTable(UserSession)
    db.createIndexIfNotExists(UserSession, "userId")
    db.createIndexIfNotExists(UserSession, "token")
    db.createIndexIfNotExists(UserSession, "expiresAt")

    if not db.tableExists(PasswordResetToken):
      db.createTable(PasswordResetToken)
    db.checkTable(PasswordResetToken)
    db.createIndexIfNotExists(PasswordResetToken, "userId")
    db.createIndexIfNotExists(PasswordResetToken, "token")
    db.createIndexIfNotExists(PasswordResetToken, "expiresAt")
  pool.syncUserCounters()

proc getUserByUsername*(pool: Pool, username: string): AccountUser =
  ## Finds one user by username.
  let rows = pool.filter(AccountUser, it.username == username)
  if rows.len > 0:
    return rows[0]
  let fallbackRows = pool.query(
    AccountUser,
    "SELECT * FROM account_user WHERE lower(username) = lower(?) LIMIT 1",
    username
  )
  if fallbackRows.len > 0:
    return fallbackRows[0]

proc getUserByEmail*(pool: Pool, email: string): AccountUser =
  ## Finds one user by email.
  let rows = pool.filter(AccountUser, it.email == email)
  if rows.len > 0:
    return rows[0]

proc getUserById*(pool: Pool, userId: int): AccountUser =
  ## Finds one user by id.
  let rows = pool.filter(AccountUser, it.id == userId)
  if rows.len > 0:
    return rows[0]

proc getUserSessionByToken*(pool: Pool, token: string): UserSession =
  ## Finds one active session by token.
  let rows = pool.filter(UserSession, it.token == token)
  if rows.len > 0:
    return rows[0]

proc getPasswordResetToken*(pool: Pool, token: string): PasswordResetToken =
  ## Finds one password reset token by token value.
  let rows = pool.filter(PasswordResetToken, it.token == token)
  if rows.len > 0:
    return rows[0]

proc countUsers*(pool: Pool): int =
  ## Returns total account count.
  pool.filter(AccountUser).len

proc listUserStats*(pool: Pool): seq[AccountUser] =
  ## Lists user account stats for profile leaderboard page.
  pool.query(
    AccountUser,
    "SELECT * FROM account_user ORDER BY post_count DESC, thread_count DESC, username ASC"
  )

proc cleanUserStatus*(value: string): string =
  ## Normalizes short user status line.
  result = value.strip()
  if result.len > 140:
    result = result[0 .. 139]

proc cleanUserBio*(value: string): string =
  ## Normalizes profile biography text.
  result = value.strip()
  if result.len > 4000:
    result = result[0 .. 3999]

proc syncUserCounters*(pool: Pool) =
  ## Recomputes per-user counters from topic/post author data.
  pool.withDb:
    let users = db.query(AccountUser, "SELECT * FROM account_user")
    for user in users:
      var
        threadCount = 0
        postCount = 0
      let threadRows = db.query(
        "SELECT COUNT(*) FROM topic WHERE author_name = ?",
        user.username
      )
      if threadRows.len > 0 and threadRows[0].len > 0:
        threadCount = threadRows[0][0].parseInt()
      let postRows = db.query(
        "SELECT COUNT(*) FROM post WHERE author_name = ?",
        user.username
      )
      if postRows.len > 0 and postRows[0].len > 0:
        postCount = postRows[0][0].parseInt()
      if user.threadCount != threadCount or user.postCount != postCount:
        user.threadCount = threadCount
        user.postCount = postCount
        user.updatedAt = nowEpoch()
        db.update(user)
proc ensureRandom() =
  ## Initializes thread-local random source once.
  if not rngInit:
    randomize()
    rngInit = true

proc randomHex(bytesLen: int): string =
  ## Generates a random lowercase hex string with the requested byte size.
  ensureRandom()
  for _ in 0 ..< bytesLen:
    result.add(toHex(rand(255), 2).toLowerAscii())

proc bytesToHex(bytes: array[32, uint8]): string =
  ## Encodes 32 bytes as lowercase hex.
  result = ""
  for b in bytes:
    result.add(toHex(b.int, 2).toLowerAscii())

proc hexValue(c: char): int =
  ## Parses one hex character into its numeric value.
  if c >= '0' and c <= '9':
    return ord(c) - ord('0')
  if c >= 'a' and c <= 'f':
    return 10 + ord(c) - ord('a')
  if c >= 'A' and c <= 'F':
    return 10 + ord(c) - ord('A')
  return -1

proc hexToBytes32(s: string): array[32, uint8] =
  ## Decodes 64-char hex text into a 32-byte array.
  if s.len != 64:
    return
  for i in 0 ..< 32:
    let hi = hexValue(s[i * 2])
    let lo = hexValue(s[i * 2 + 1])
    if hi < 0 or lo < 0:
      return
    result[i] = uint8((hi shl 4) or lo)

proc makePasswordSalt*(): string =
  ## Generates one password salt as hex.
  randomHex(SaltBytes)

proc makePasswordToken*(): string =
  ## Generates one account token value as hex.
  randomHex(TokenBytes)

proc makePasswordHash*(
  serverSecret: string,
  username: string,
  password: string,
  salt: string,
  iterations = DefaultPasswordIterations
): string =
  ## Creates PBKDF2-HMAC-SHA256 password hash as lowercase hex.
  let input = serverSecret & ":" & username & ":" & password
  let digest = pbkdf2(input, salt, iterations)
  bytesToHex(digest)

proc verifyPasswordHash*(
  serverSecret: string,
  username: string,
  password: string,
  salt: string,
  expectedHash: string,
  iterations: int
): bool =
  ## Verifies candidate password against stored salt/hash/iteration fields.
  let input = serverSecret & ":" & username & ":" & password
  let expected = hexToBytes32(expectedHash)
  let actual = pbkdf2(input, salt, iterations)
  for i in 0 ..< 32:
    if actual[i] != expected[i]:
      return false
  true

proc nowEpoch*(): int64 =
  ## Returns current unix timestamp.
  models.nowEpoch()

proc cleanUsername*(username: string): string =
  ## Trims and normalizes username text.
  username.strip()

proc cleanEmail*(email: string): string =
  ## Trims and lowercases email text.
  email.strip().toLowerAscii()

proc parseCookieValue*(cookieHeader: string, key: string): string =
  ## Extracts one cookie value from a Cookie header.
  for rawPart in cookieHeader.split(';'):
    let part = rawPart.strip()
    let sep = part.find('=')
    if sep <= 0:
      continue
    let name = part[0 ..< sep].strip()
    if name == key:
      return part[sep + 1 .. ^1].strip()

proc sessionCookieValue*(request: Request): string =
  ## Returns session token from request cookies.
  parseCookieValue(request.headers["Cookie"], "nobby_session")

proc makeSessionSetCookie*(token: string): string =
  ## Builds Set-Cookie header for a session token.
  "nobby_session=" & token & "; Path=/; HttpOnly; SameSite=Lax"

proc makeClearSessionCookie*(): string =
  ## Builds Set-Cookie header to clear a session token.
  "nobby_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"

proc createSession*(pool: Pool, userId: int, ttlSeconds = 60 * 60 * 24 * 30): UserSession =
  ## Creates and stores one user session token.
  result = UserSession(
    userId: userId,
    token: makePasswordToken(),
    expiresAt: nowEpoch() + int64(ttlSeconds),
    createdAt: nowEpoch()
  )
  pool.insert(result)

proc clearSession*(pool: Pool, token: string) =
  ## Deletes one session token if it exists.
  if token.len == 0:
    return
  pool.withDb:
    discard db.query("DELETE FROM user_session WHERE token = ?", token)

proc getCurrentUser*(pool: Pool, request: Request): AccountUser =
  ## Resolves current signed-in user from request session cookie.
  let token = request.sessionCookieValue()
  if token.len == 0:
    return nil
  let session = pool.getUserSessionByToken(token)
  if session.isNil:
    return nil
  if session.expiresAt <= nowEpoch():
    pool.clearSession(token)
    return nil
  pool.getUserById(session.userId)

proc createUser*(
  pool: Pool,
  serverSecret: string,
  username: string,
  email: string,
  password: string
): AccountUser =
  ## Creates one new user with stored PBKDF2 password data.
  let cleanName = cleanUsername(username)
  let cleanMail = cleanEmail(email)
  let ts = nowEpoch()
  let salt = makePasswordSalt()
  result = AccountUser(
    username: cleanName,
    email: cleanMail,
    threadCount: 0,
    postCount: 0,
    userStatus: "",
    userBio: "",
    passwordSalt: salt,
    passwordHash: makePasswordHash(serverSecret, cleanName, password, salt),
    passwordIterations: DefaultPasswordIterations,
    createdAt: ts,
    updatedAt: ts
  )
  pool.insert(result)

proc authenticateUser*(
  pool: Pool,
  serverSecret: string,
  username: string,
  password: string
): AccountUser =
  ## Verifies username/password and returns user on success.
  let cleanName = cleanUsername(username)
  let user = pool.getUserByUsername(cleanName)
  if user.isNil:
    return nil
  if not verifyPasswordHash(
    serverSecret,
    user.username,
    password,
    user.passwordSalt,
    user.passwordHash,
    user.passwordIterations
  ):
    return nil
  user

proc createPasswordResetToken*(
  pool: Pool,
  userId: int,
  ttlSeconds = 60 * 30
): PasswordResetToken =
  ## Creates one password reset token for a user.
  result = PasswordResetToken(
    userId: userId,
    token: makePasswordToken(),
    expiresAt: nowEpoch() + int64(ttlSeconds),
    usedAt: 0,
    createdAt: nowEpoch()
  )
  pool.insert(result)

proc consumePasswordResetToken*(
  pool: Pool,
  tokenValue: string
): PasswordResetToken =
  ## Marks a reset token as used and returns it.
  let token = pool.getPasswordResetToken(tokenValue)
  if token.isNil:
    return nil
  if token.usedAt > 0:
    return nil
  if token.expiresAt <= nowEpoch():
    return nil
  token.usedAt = nowEpoch()
  pool.update(token)
  token

proc setUserPassword*(
  pool: Pool,
  serverSecret: string,
  user: AccountUser,
  password: string
) =
  ## Replaces a user's password hash fields.
  let salt = makePasswordSalt()
  user.passwordSalt = salt
  user.passwordHash = makePasswordHash(serverSecret, user.username, password, salt)
  user.passwordIterations = DefaultPasswordIterations
  user.updatedAt = nowEpoch()
  pool.update(user)

proc incrementThreadAndPostCount*(pool: Pool, user: AccountUser) =
  ## Increments both thread and post counters after creating a thread.
  if user.isNil:
    return
  user.threadCount += 1
  user.postCount += 1
  user.updatedAt = nowEpoch()
  pool.update(user)

proc incrementPostCount*(pool: Pool, user: AccountUser) =
  ## Increments post counter after adding a reply.
  if user.isNil:
    return
  user.postCount += 1
  user.updatedAt = nowEpoch()
  pool.update(user)

proc updateUserProfile*(pool: Pool, user: AccountUser, statusText: string, bioText: string) =
  ## Updates editable profile fields for one user.
  if user.isNil:
    return
  user.userStatus = cleanUserStatus(statusText)
  user.userBio = cleanUserBio(bioText)
  user.updatedAt = nowEpoch()
  pool.update(user)

proc renderAccountLayout*(
  pageTitle: string,
  content: string,
  currentUsername = "",
  isAdmin = false
): string =
  ## Renders shared account page shell.
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
          table ".lineup header-layout":
            tr:
              td ".smalltext":
                p ".smalltext":
                  span ".maintitle":
                    say "Nobby, a bulletin board style forum"
                p ".smalltext":
                  say "Visual forum inspired by the early 2000s message boards."
              td ".right.smalltext account-cell":
                if currentUsername.len == 0:
                  a:
                    href "/login"
                    say "Login"
                  say " | "
                  a:
                    href "/register"
                    say "Register"
                else:
                  say "User: "
                  b:
                    a ".topiclink":
                      href "/u/" & currentUsername
                      say esc(currentUsername)
                  if isAdmin:
                    say " | "
                    a:
                      href "/users"
                      say "Users"
                  say " | "
                  a:
                    href "/logout"
                    say "Logout"
          p ".navigation":
            a:
              href "/"
              say "Index"
            if currentUsername.len == 0:
              say " | "
              a:
                href "/register"
                say "Register"
              say " | "
              a:
                href "/login"
                say "Login"
              say " | "
              a:
                href "/forgot-password"
                say "Forgot Password"
              say " | "
              a:
                href "/forgot-username"
                say "Forgot Username"
            else:
              if isAdmin:
                say " | "
                a:
                  href "/users"
                  say "Users"
              say " | "
              a:
                href "/logout"
                say "Logout"
          say content
          p ".footer-note":
            say "Copyright 2026 Nobby. MIT License."

proc renderUserBioMarkdown(text: string): string =
  ## Converts user bio markdown to safe HTML.
  markdown(
    text,
    config = initGfmConfig(
      escape = true,
      keepHtml = false
    )
  )

proc renderAccountMessage*(
  title: string,
  message: string
): string =
  ## Renders one reusable account status block.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say esc(title)
        tr:
          td ".row2":
            p ".mediumtext":
              say esc(message)
            p ".smalltext":
              a:
                href "/"
                say "Back to index"
  renderAccountLayout(title, content)

proc renderRegisterPage*(
  errorMessage = "",
  username = "",
  email = ""
): string =
  ## Renders register form page.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Create account"
        tr:
          td ".row2":
            if errorMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(errorMessage)
            form ".post-form":
              action "/register"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "register-username"
                  say "Username"
                input "#register-username":
                  ttype "text"
                  name "username"
                  value esc(username)
              tdiv ".form-row":
                label ".smalltext":
                  tfor "register-email"
                  say "Email"
                input "#register-email":
                  ttype "email"
                  name "email"
                  value esc(email)
              tdiv ".form-row":
                label ".smalltext":
                  tfor "register-password"
                  say "Password"
                input "#register-password":
                  ttype "password"
                  name "password"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "register-repeat"
                  say "Repeat password"
                input "#register-repeat":
                  ttype "password"
                  name "repeatPassword"
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Register"
  renderAccountLayout("Register", content)

proc renderLoginPage*(
  errorMessage = "",
  username = ""
): string =
  ## Renders login form page.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Login"
        tr:
          td ".row2":
            if errorMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(errorMessage)
            form ".post-form":
              action "/login"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "login-username"
                  say "Username"
                input "#login-username":
                  ttype "text"
                  name "username"
                  value esc(username)
              tdiv ".form-row":
                label ".smalltext":
                  tfor "login-password"
                  say "Password"
                input "#login-password":
                  ttype "password"
                  name "password"
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Login"
            p ".smalltext":
              a:
                href "/forgot-password"
                say "Forgot password?"
              say " "
              a:
                href "/forgot-username"
                say "Forgot username?"
  renderAccountLayout("Login", content)

proc renderForgotPasswordPage*(
  infoMessage = "",
  email = ""
): string =
  ## Renders forgot-password request form.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Forgot password"
        tr:
          td ".row2":
            if infoMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(infoMessage)
            form ".post-form":
              action "/forgot-password"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "forgot-password-email"
                  say "Email"
                input "#forgot-password-email":
                  ttype "email"
                  name "email"
                  value esc(email)
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Send reset link"
  renderAccountLayout("Forgot Password", content)

proc renderResetPasswordPage*(
  token = "",
  errorMessage = ""
): string =
  ## Renders password reset form.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Reset password"
        tr:
          td ".row2":
            if errorMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(errorMessage)
            form ".post-form":
              action "/reset-password"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "reset-token"
                  say "Token"
                input "#reset-token":
                  ttype "text"
                  name "token"
                  value esc(token)
              tdiv ".form-row":
                label ".smalltext":
                  tfor "reset-password"
                  say "New password"
                input "#reset-password":
                  ttype "password"
                  name "password"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "reset-repeat"
                  say "Repeat password"
                input "#reset-repeat":
                  ttype "password"
                  name "repeatPassword"
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Update password"
  renderAccountLayout("Reset Password", content)

proc renderForgotUsernamePage*(
  infoMessage = "",
  email = ""
): string =
  ## Renders forgot-username request form.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Forgot username"
        tr:
          td ".row2":
            if infoMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(infoMessage)
            form ".post-form":
              action "/forgot-username"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "forgot-username-email"
                  say "Email"
                input "#forgot-username-email":
                  ttype "email"
                  name "email"
                  value esc(email)
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Send username reminder"
  renderAccountLayout("Forgot Username", content)

proc renderUsersPage*(
  rows: seq[AccountUser],
  showEmails: bool,
  currentUsername = "",
  isAdmin = false,
  currentPage = 1,
  pageCount = 1
): string =
  ## Renders account statistics listing page.
  let pagination = renderPagination("/users", currentPage, pageCount)
  let content = renderFragment:
    section "#post.section":
      say pagination
      table ".grid post-layout":
        tr:
          td ".toprow authorcol":
            say "Username"
          if showEmails:
            td ".toprow":
              say "Email"
          td ".toprow":
            say "Threads"
          td ".toprow":
            say "Posts"
        if rows.len == 0:
          tr:
            td ".row1":
              if showEmails:
                colspan "4"
              else:
                colspan "3"
              say "No users found."
        for row in rows:
          tr:
            td ".row1 authorcol":
              a ".topiclink":
                href "/u/" & row.username
                if row.isAdmin:
                  b:
                    say row.username & " (admin)"
                else:
                  say row.username
            if showEmails:
              td ".row2":
                say row.email
            td ".row1":
              say $row.threadCount
            td ".row2":
              say $row.postCount
      say pagination
  renderLayout(
    "Users",
    content,
    currentUsername,
    @[("Index", "/"), ("Users", "")],
    isAdmin
  )

proc commentCount(user: AccountUser): int =
  ## Returns reply count excluding thread starter posts.
  if user.isNil:
    return 0
  max(0, user.postCount - user.threadCount)

proc renderUserPage*(
  user: AccountUser,
  currentUsername = "",
  isAdmin = false,
  canEdit = false
): string =
  ## Renders one public user profile page.
  let content = renderFragment:
    section "#post.section":
      table ".grid post-layout":
        tr:
          td ".toprow authorcol":
            say "User"
          td ".toprow":
            say "Profile"
          td ".toprow":
            say "Stats"
        tr:
          td ".row1 authorcol":
            b:
              say user.username
            if user.userStatus.len > 0:
              p ".smalltext":
                say esc(user.userStatus)
          td ".row2 postbody":
            p ".smalltext":
              b:
                say "Bio"
            if user.userBio.len > 0:
              say renderUserBioMarkdown(user.userBio)
            else:
              p ".smalltext":
                say "No bio yet."
          td ".row1":
            p ".smalltext":
              say "Posts: " & $user.threadCount
            p ".smalltext":
              say "Comments: " & $commentCount(user)
            p ".smalltext":
              say "Total entries: " & $user.postCount
      if canEdit:
        section "#compose.section":
          table ".grid":
            tr:
              td ".row2":
                form ".post-form":
                  action "/u/" & user.username & "/edit"
                  tmethod "get"
                  tdiv ".form-actions":
                    button ".btn":
                      ttype "submit"
                      say "Edit profile"
  renderLayout(
    user.username,
    content,
    currentUsername,
    @[("Index", "/"), ("Users", "/users"), (user.username, "")],
    isAdmin
  )

proc renderEditUserPage*(
  user: AccountUser,
  errorMessage = "",
  currentUsername = "",
  isAdmin = false
): string =
  ## Renders editable profile form for one account.
  let content = renderFragment:
    section "#account.section":
      table ".grid":
        tr:
          td ".toprow":
            say "Edit profile"
        tr:
          td ".row2":
            if errorMessage.len > 0:
              p ".smalltext":
                b:
                  say esc(errorMessage)
            form ".post-form":
              action "/u/" & user.username & "/edit"
              tmethod "post"
              tdiv ".form-row":
                label ".smalltext":
                  tfor "user-status"
                  say "Status"
                input "#user-status":
                  ttype "text"
                  name "userStatus"
                  value esc(user.userStatus)
              tdiv ".form-row":
                label ".smalltext":
                  tfor "user-bio"
                  say "Bio"
                textarea "#user-bio":
                  name "userBio"
                  say esc(user.userBio)
              tdiv ".form-actions":
                button ".btn":
                  ttype "submit"
                  say "Save profile"
  renderLayout(
    "Edit profile",
    content,
    currentUsername,
    @[("Index", "/"), ("Users", "/users"), (user.username, "/u/" & user.username), ("Edit", "")],
    isAdmin
  )
