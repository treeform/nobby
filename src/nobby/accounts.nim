import
  std/[random, strutils],
  crunchy/sha256,
  debby/[pools, sqlite],
  mummy,
  taggy,
  models

const
  DefaultPasswordIterations* = 120_000
  SaltBytes = 16
  TokenBytes = 24

var
  rngInit {.threadvar.}: bool

type
  AccountUser* = ref object
    id*: int
    username*: string
    email*: string
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

proc getUserByUsername*(pool: Pool, username: string): AccountUser =
  ## Finds one user by username.
  let rows = pool.filter(AccountUser, it.username == username)
  if rows.len > 0:
    return rows[0]

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

proc esc(text: string): string =
  ## Escapes HTML special characters.
  result = text
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc renderAccountLayout*(
  pageTitle: string,
  content: string
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
          p ".smalltext":
            span ".maintitle":
              say "Nobby, a bulletin board style forum"
          p ".smalltext":
            say "Visual forum inspired by the early 2000s message boards."
          p ".navigation":
            a:
              href "/"
              say "Index"
            a:
              href "/register"
              say "Register"
            a:
              href "/login"
              say "Login"
            a:
              href "/forgot-password"
              say "Forgot Password"
            a:
              href "/forgot-username"
              say "Forgot Username"
          say content
          p ".footer-note":
            say "Visual forum inspired by the early 2000s message boards."

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
