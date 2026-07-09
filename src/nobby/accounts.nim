import
  std/[os, strutils, sysrand],
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
  ServerSecretPath* = "server.secret"
  ServerSecretBytes = 32
  UsernameMinLen* = 3
  UsernameMaxLen* = 30
  UsernameAllowedChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}

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

  CountRow = ref object
    count: int

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
    # Debby createIndex is non-unique, so enforce uniqueness with raw SQL.
    discard db.query(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_username_lower ON account_user(lower(username))"
    )
    discard db.query(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_account_user_email_unique ON account_user(email)"
    )

    if not db.tableExists(UserSession):
      db.createTable(UserSession)
    db.checkTable(UserSession)
    db.createIndexIfNotExists(UserSession, "userId")
    discard db.query(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_user_session_token_unique ON user_session(token)"
    )
    db.createIndexIfNotExists(UserSession, "expiresAt")

    if not db.tableExists(PasswordResetToken):
      db.createTable(PasswordResetToken)
    db.checkTable(PasswordResetToken)
    db.createIndexIfNotExists(PasswordResetToken, "userId")
    discard db.query(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_token_token_unique ON password_reset_token(token)"
    )
    db.createIndexIfNotExists(PasswordResetToken, "expiresAt")
  pool.syncUserCounters()

proc isUniqueConstraintError*(e: ref Exception): bool =
  ## Returns true when an exception looks like a UNIQUE constraint failure.
  "UNIQUE" in e.msg.toUpperAscii()

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
  let rows = pool.query(
    CountRow,
    "SELECT COUNT(*) AS count FROM account_user"
  )
  if rows.len > 0:
    return rows[0].count

proc listUserStats*(
  pool: Pool,
  page = 1,
  pageSize = 30
): seq[AccountUser] =
  ## Lists paged user account stats for profile leaderboard page.
  let
    safePage = max(1, page)
    safePageSize = max(1, pageSize)
    offset = (safePage - 1) * safePageSize
  pool.query(
    AccountUser,
    """
    SELECT * FROM account_user
    ORDER BY post_count DESC, thread_count DESC, username ASC
    LIMIT ? OFFSET ?
    """,
    safePageSize,
    offset
  )

proc cleanUserStatus*(value: string): string =
  ## Normalizes short user status line.
  truncateUtf8(value.strip(), 140)

proc cleanUserBio*(value: string): string =
  ## Normalizes profile biography text.
  truncateUtf8(value.strip(), 4000)

proc syncUserCounters*(pool: Pool) =
  ## Recomputes per-user counters from topic/post author data.
  pool.withDb:
    discard db.query(
      """
      UPDATE account_user AS u
      SET
        thread_count = c.thread_count,
        post_count = c.post_count,
        updated_at = ?
      FROM (
        SELECT
          id AS id,
          COALESCE((
            SELECT COUNT(*) FROM topic WHERE author_name = account_user.username
          ), 0) AS thread_count,
          COALESCE((
            SELECT COUNT(*) FROM post WHERE author_name = account_user.username
          ), 0) AS post_count
        FROM account_user
      ) AS c
      WHERE u.id = c.id
        AND (
          u.thread_count != c.thread_count
          OR u.post_count != c.post_count
        )
      """,
      nowEpoch()
    )

proc bytesToHex(bytes: openArray[byte]): string =
  ## Encodes bytes as lowercase hex.
  for b in bytes:
    result.add(toHex(b.int, 2).toLowerAscii())

proc randomHex(bytesLen: int): string =
  ## Generates a cryptographically random lowercase hex string.
  var bytes = newSeq[byte](bytesLen)
  if not urandom(bytes):
    raise newException(IOError, "Failed to generate random bytes.")
  bytesToHex(bytes)

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

proc makeServerSecretValue(): string =
  ## Generates one cryptographically random server secret as hex.
  randomHex(ServerSecretBytes)

proc loadServerSecret*(path = ServerSecretPath): string =
  ## Loads password pepper from env, or a local secret file.
  ## Creates the secret file with owner-only permissions when missing.
  result = getEnv("NOBBY_SERVER_SECRET").strip()
  if result.len > 0:
    return
  if fileExists(path):
    result = readFile(path).strip()
    if result.len == 0:
      raise newException(IOError, "Server secret file is empty: " & path)
    return
  result = makeServerSecretValue()
  writeFile(path, result & "\n")
  when defined(posix):
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  stderr.writeLine("[secret] Created ", path)

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

proc constantTimeEquals(a, b: array[32, uint8]): bool =
  ## Compares two digests without early exit on the first mismatch.
  var diff: uint8 = 0
  for i in 0 ..< 32:
    diff = diff or (a[i] xor b[i])
  diff == 0

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
  constantTimeEquals(actual, expected)

proc nowEpoch*(): int64 =
  ## Returns current unix timestamp.
  models.nowEpoch()

proc cleanUsername*(username: string): string =
  ## Trims username text.
  username.strip()

proc isValidUsername*(username: string): bool =
  ## Returns true for ASCII usernames with letters, digits, _ or -.
  if username.len < UsernameMinLen or username.len > UsernameMaxLen:
    return false
  for c in username:
    if c notin UsernameAllowedChars:
      return false
  true

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

proc csrfCookieValue*(request: Request): string =
  ## Returns CSRF token from request cookies.
  parseCookieValue(request.headers["Cookie"], "nobby_csrf")

proc secureCookiesEnabled*(): bool =
  ## Returns true when Secure cookie attributes should be set.
  let value = getEnv("NOBBY_SECURE_COOKIES").strip().toLowerAscii()
  value in ["1", "true", "yes", "on"]

proc cookieSecuritySuffix*(): string =
  ## Returns optional Secure attribute for cookie headers.
  if secureCookiesEnabled():
    return "; Secure"
  ""

proc makeCsrfToken*(): string =
  ## Generates one CSRF token value as hex.
  randomHex(TokenBytes)

proc makeCsrfSetCookie*(token: string): string =
  ## Builds Set-Cookie header for a CSRF token.
  "nobby_csrf=" & token & "; Path=/; SameSite=Lax" & cookieSecuritySuffix()

proc makeClearCsrfCookie*(): string =
  ## Builds Set-Cookie header to clear a CSRF token.
  "nobby_csrf=; Path=/; SameSite=Lax; Max-Age=0" & cookieSecuritySuffix()

proc csrfTokensMatch*(cookieToken: string, formToken: string): bool =
  ## Returns true when cookie and form CSRF tokens are present and equal.
  cookieToken.len > 0 and formToken.len > 0 and cookieToken == formToken

proc makeSessionSetCookie*(token: string, ttlSeconds = 60 * 60 * 24 * 30): string =
  ## Builds Set-Cookie header for a session token.
  "nobby_session=" & token &
    "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" & $ttlSeconds &
    cookieSecuritySuffix()

proc makeClearSessionCookie*(): string =
  ## Builds Set-Cookie header to clear a session token.
  "nobby_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" &
    cookieSecuritySuffix()

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

proc clearSessionsForUser*(pool: Pool, userId: int) =
  ## Deletes all session tokens for one user.
  if userId <= 0:
    return
  pool.withDb:
    discard db.query("DELETE FROM user_session WHERE user_id = ?", userId)

proc clearUnusedPasswordResetTokens*(pool: Pool, userId: int) =
  ## Deletes unused password reset tokens for one user.
  if userId <= 0:
    return
  pool.withDb:
    discard db.query(
      "DELETE FROM password_reset_token WHERE user_id = ? AND used_at = 0",
      userId
    )

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
  if not isValidUsername(cleanName):
    raise newException(
      ValueError,
      "Username must be ASCII letters, digits, _ or -."
    )
  if not pool.getUserByUsername(cleanName).isNil:
    raise newException(DbError, "UNIQUE constraint failed: username")
  if not pool.getUserByEmail(cleanMail).isNil:
    raise newException(DbError, "UNIQUE constraint failed: email")
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
  try:
    pool.insert(result)
  except DbError as e:
    if isUniqueConstraintError(e):
      raise e
    raise

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
  ## Replaces a user's password hash and revokes existing sessions.
  let salt = makePasswordSalt()
  user.passwordSalt = salt
  user.passwordHash = makePasswordHash(serverSecret, user.username, password, salt)
  user.passwordIterations = DefaultPasswordIterations
  user.updatedAt = nowEpoch()
  pool.update(user)
  pool.clearSessionsForUser(user.id)
  pool.clearUnusedPasswordResetTokens(user.id)

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
  isAdmin = false,
  csrfToken = ""
): string =
  ## Renders shared account page shell.
  let csrfField = renderCsrfField(csrfToken)
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
                  form ".inline-form":
                    action "/logout"
                    tmethod "post"
                    say csrfField
                    button ".linkish":
                      ttype "submit"
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
              form ".inline-form":
                action "/logout"
                tmethod "post"
                say csrfField
                button ".linkish":
                  ttype "submit"
                  say "Logout"
          say content
          p ".footer-note":
            say "Copyright 2026 Nobby. MIT License."

proc renderUserBioMarkdown(text: string): string =
  ## Converts user bio markdown to safe HTML.
  renderSafeMarkdown(text)

proc renderAccountMessage*(
  title: string,
  message: string,
  csrfToken = ""
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
  renderAccountLayout(title, content, csrfToken = csrfToken)

proc renderRegisterPage*(
  errorMessage = "",
  username = "",
  email = "",
  csrfToken = ""
): string =
  ## Renders register form page.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
  renderAccountLayout("Register", content, csrfToken = csrfToken)

proc renderLoginPage*(
  errorMessage = "",
  username = "",
  csrfToken = ""
): string =
  ## Renders login form page.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
  renderAccountLayout("Login", content, csrfToken = csrfToken)

proc renderForgotPasswordPage*(
  infoMessage = "",
  email = "",
  csrfToken = ""
): string =
  ## Renders forgot-password request form.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
  renderAccountLayout("Forgot Password", content, csrfToken = csrfToken)

proc renderResetPasswordPage*(
  token = "",
  errorMessage = "",
  csrfToken = ""
): string =
  ## Renders password reset form.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
  renderAccountLayout("Reset Password", content, csrfToken = csrfToken)

proc renderForgotUsernamePage*(
  infoMessage = "",
  email = "",
  csrfToken = ""
): string =
  ## Renders forgot-username request form.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
  renderAccountLayout("Forgot Username", content, csrfToken = csrfToken)

proc renderUsersPage*(
  rows: seq[AccountUser],
  showEmails: bool,
  currentUsername = "",
  isAdmin = false,
  currentPage = 1,
  pageCount = 1,
  csrfToken = ""
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
                    say esc(row.username) & " (admin)"
                else:
                  say esc(row.username)
            if showEmails:
              td ".row2":
                say esc(row.email)
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
    isAdmin,
    csrfToken = csrfToken
  )

proc replyCount(user: AccountUser): int =
  ## Returns reply count excluding thread starter posts.
  if user.isNil:
    return 0
  max(0, user.postCount - user.threadCount)

proc renderUserPage*(
  user: AccountUser,
  currentUsername = "",
  isAdmin = false,
  canEdit = false,
  csrfToken = ""
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
              say esc(user.username)
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
              say "Threads: " & $user.threadCount
            p ".smalltext":
              say "Replies: " & $replyCount(user)
            p ".smalltext":
              say "Posts: " & $user.postCount
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
    isAdmin,
    csrfToken = csrfToken
  )

proc renderEditUserPage*(
  user: AccountUser,
  errorMessage = "",
  currentUsername = "",
  isAdmin = false,
  csrfToken = ""
): string =
  ## Renders editable profile form for one account.
  let csrfField = renderCsrfField(csrfToken)
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
              say csrfField
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
    isAdmin,
    csrfToken = csrfToken
  )
