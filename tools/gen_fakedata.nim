import
  std/[os, sets, strutils],
  debby/pools,
  debby/sqlite,
  ../src/nobby/[accounts, models]
type
  SeedReply = tuple[author: string, body: string]
  SeedTopic = object
    title: string
    starter: string
    body: string
    replies: seq[SeedReply]
  SeedBoard = object
    section: string
    slug: string
    title: string
    description: string
    topics: seq[SeedTopic]
    emptyTopicCount: int
proc nextStamp(clock: var int64, stepSeconds = 240): int64 =
  ## Returns an increasing timestamp for realistic fake posts.
  clock += stepSeconds.int64
  result = clock
proc insertBoardData(pool: Pool, boardSeed: SeedBoard, clock: var int64): tuple[topics: int, replies: int] =
  ## Inserts one board with topics and replies into the database.
  var board = Board(
    section: boardSeed.section,
    slug: boardSeed.slug,
    title: boardSeed.title,
    description: boardSeed.description,
    createdAt: nextStamp(clock)
  )
  pool.insert(board)
  for topicSeed in boardSeed.topics:
    let topic = pool.createTopicWithFirstPost(
      board.id,
      topicSeed.title,
      topicSeed.starter,
      topicSeed.body,
      nextStamp(clock)
    )
    inc result.topics
    for replySeed in topicSeed.replies:
      discard pool.createReply(
        topic.id,
        replySeed.author,
        replySeed.body,
        nextStamp(clock)
      )
      inc result.replies
  if boardSeed.emptyTopicCount > 0:
    for i in 1 .. boardSeed.emptyTopicCount:
      var topic = Topic(
        boardId: board.id,
        title: "Pagination placeholder topic #" & $i,
        authorName: "Admin",
        createdAt: nextStamp(clock),
        updatedAt: clock
      )
      pool.insert(topic)
      inc result.topics

proc makePaginationReplies(count: int): seq[SeedReply] =
  ## Builds a sequence of replies to force pagination in one topic.
  for i in 1 .. count:
    result.add((
      author: "ThreadPilot" & $((i mod 7) + 1),
      body: "Pagination reply #" & $i & "\n\n- checkpoint: " & $i & "\n- orbit: stable"
    ))

proc ensureAccount(pool: Pool, serverSecret: string, username: string) =
  ## Creates one account for a posting user if missing.
  if username.len == 0:
    return
  if not pool.getUserByUsername(username).isNil:
    return
  let normalized = username.toLowerAscii()
  let email = normalized & "@example.com"
  discard pool.createUser(serverSecret, username, email, "hunter2")

proc seedPostingAccounts(pool: Pool, seeds: seq[SeedBoard], serverSecret: string) =
  ## Creates accounts for every user who appears in posting data.
  var authors = initHashSet[string]()
  for boardSeed in seeds:
    for topicSeed in boardSeed.topics:
      if topicSeed.starter.len > 0:
        authors.incl(topicSeed.starter)
      for replySeed in topicSeed.replies:
        if replySeed.author.len > 0:
          authors.incl(replySeed.author)
  for author in authors.items:
    pool.ensureAccount(serverSecret, author)
  var admin = pool.getUserByUsername("Admin")
  if admin.isNil:
    admin = pool.createUser(serverSecret, "Admin", "admin@examle.com", "hunter2")
  if not admin.isNil and not admin.isAdmin:
    admin.isAdmin = true
    admin.updatedAt = models.nowEpoch()
    pool.update(admin)

proc makeSeeds(): seq[SeedBoard] =
  ## Builds all space-themed boards, topics, and replies.
  result = @[
    SeedBoard(
      section: "General Discussions",
      slug: "stargazing",
      title: "Stargazing Deck",
      description: "Night sky logs, telescopes, and first sightings.",
      topics: @[
        SeedTopic(
          title: "First telescope for city skies?",
          starter: "NovaScout",
          body: "I can only see a slice of sky from my balcony.\n\n## Goals\n- See Saturn clearly\n- Keep setup simple\n\n`budget <= starter`",
          replies: @[
            (author: "SkyMoth", body: "Start with a small Dobsonian and a wide eyepiece. Keep your first setup simple and stable."),
            (author: "CloudPioneer", body: "A decent tripod matters more than zoom numbers.\n\n**Vibration** can ruin the view."),
            (author: "MoonRanger", body: "Use a planet app just for locating, then switch it off and let your eyes adapt.")
          ]
        ),
        SeedTopic(
          title: "Meteor shower watch thread",
          starter: "OrbitCat",
          body: "Open thread for this weekend. Post your location, cloud cover, and best sightings.",
          replies: @[
            (author: "NightSignal", body: "North ridge reporting in. Thin clouds, still caught 14 streaks in 40 minutes."),
            (author: "DustyScope", body: "Urban sky here, only saw 3 but one was bright green."),
            (author: "AstraNim", body: "Bring a foldable chair. Neck pain ended my first watch way too early.")
          ]
        ),
        SeedTopic(
          title: "Do you sketch what you see?",
          starter: "GlassFinder",
          body: "I started making tiny notebook sketches while observing. It helps me notice details I miss in photos.",
          replies: @[
            (author: "PaleComet", body: "Yes. Sketching makes me slow down and compare brightness between stars."),
            (author: "ZenithFox", body: "I do rough circles and labels only. Quick and useful for later checks."),
            (author: "HelioKid", body: "Try soft pencils. You can smudge faint nebula edges very easily.")
          ]
        ),
        SeedTopic(
          title: "Long running observations thread",
          starter: "ThreadPilot1",
          body: "This thread intentionally has many replies to test paging.\n\n### Notes\n- Keep posting small updates\n- Include quick markdown",
          replies: makePaginationReplies(39)
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Planets",
      slug: "mercury-outpost",
      title: "Mercury Outpost",
      description: "Heat shields, dawn flights, and crater camp ideas.",
      topics: @[
        SeedTopic(
          title: "Would you build in a crater rim?",
          starter: "SunlinePilot",
          body: "If we had a small station on Mercury, would a crater rim be safer for temperature swings?",
          replies: @[
            (author: "TerminatorRun", body: "Rim shadows are useful, but dust movement near slopes could be rough."),
            (author: "IronRegolith", body: "I would vote for modular habitats that can relocate as needed."),
            (author: "MapRoom", body: "Power routing is the hard part. Panels need careful angle planning.")
          ]
        ),
        SeedTopic(
          title: "Best rover tires for sharp dust",
          starter: "FurnaceWalker",
          body: "Mercury terrain feels like it would shred normal rover wheels. Any material ideas?",
          replies: @[
            (author: "AlloyPilot", body: "Spring mesh with replaceable outer bands seems practical."),
            (author: "QuietOrbit", body: "Dual wheel layers could give backup when one layer gets punctured."),
            (author: "ForgeKid", body: "Keep wheel design simple so local repair bots can patch quickly.")
          ]
        ),
        SeedTopic(
          title: "Sunrise photo challenge",
          starter: "RedVisor",
          body: "Post your imagined Mercury sunrise setup. What lens and what safety filters?",
          replies: @[
            (author: "ShadeLine", body: "Wide lens with hard edge filters. I want the horizon and station silhouettes."),
            (author: "VectorGlow", body: "Telephoto plus remote shutters only. No direct handling near glare."),
            (author: "PilotZero", body: "I would bracket exposure heavily. Light contrast there is wild.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Planets",
      slug: "venus-cloud-city",
      title: "Venus Cloud City",
      description: "Floating habitats, pressure systems, and sulfur-proof gear.",
      topics: @[
        SeedTopic(
          title: "Could balloons host permanent labs?",
          starter: "CloudNomad",
          body: "At high altitude the pressure is friendlier. Could floating labs become true cities?",
          replies: @[
            (author: "AcidProof", body: "Permanent maybe, but maintenance cycles would be nonstop."),
            (author: "DriftChart", body: "Distributed balloon clusters sound safer than one giant platform."),
            (author: "LiftEngineer", body: "Gas leak detection must be redundant and very boring on purpose.")
          ]
        ),
        SeedTopic(
          title: "Favorite Venus weather model papers",
          starter: "AeroNim",
          body: "Drop references for approachable weather simulations for high atmosphere routes.",
          replies: @[
            (author: "JetRibbon", body: "Look for layered circulation models with clear boundary assumptions."),
            (author: "SulfurTea", body: "I like papers with open data tables more than pretty charts."),
            (author: "ArcMeter", body: "Older papers still hold up if you cross-check constants.")
          ]
        ),
        SeedTopic(
          title: "Station naming ideas",
          starter: "LanternWing",
          body: "Should Venus stations use myth names, cloud names, or practical IDs only?",
          replies: @[
            (author: "PragmaCore", body: "Use practical IDs for operations and informal nicknames socially."),
            (author: "MythSignal", body: "Myth names add character and are easier to remember."),
            (author: "GridPilot", body: "Both systems can coexist if the docs are consistent.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "General Discussions",
      slug: "lunar-yard",
      title: "Lunar Yard",
      description: "Moon base routines, dust mitigation, and low-gravity tools.",
      topics: @[
        SeedTopic(
          title: "How often should airlocks cycle cleaning?",
          starter: "DustMarshal",
          body: "Moon dust gets everywhere. What cleaning rhythm keeps tools usable without wasting time?",
          replies: @[
            (author: "SealTech", body: "Quick brush every cycle, deep clean every shift change."),
            (author: "GreyBoots", body: "Separate dirty and clean lockers made the biggest difference."),
            (author: "FoamPilot", body: "Use simple checklist tags so nobody skips final checks.")
          ]
        ),
        SeedTopic(
          title: "Best first build near base",
          starter: "RegolithRay",
          body: "After habitat and power, what should be third priority: workshop, greenhouse, or radio tower?",
          replies: @[
            (author: "SpannerKid", body: "Workshop first. Repair capacity keeps everything else alive."),
            (author: "LeafDrive", body: "Greenhouse early helps morale and long-term supply planning."),
            (author: "BeaconBlue", body: "Radio tower if terrain blocks line-of-sight to orbit relays.")
          ]
        ),
        SeedTopic(
          title: "Favorite low-gravity sport ideas",
          starter: "HopEngine",
          body: "Serious question. What games would become fun in one-sixth gravity?",
          replies: @[
            (author: "ArcRunner", body: "Slow dodgeball with huge court spacing sounds amazing."),
            (author: "PulseTape", body: "Obstacle races with precision jumps and tether rules."),
            (author: "DriftMason", body: "Anything with long arcs and team timing would be great.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Planets",
      slug: "mars-colony",
      title: "Mars Colony Commons",
      description: "Habitats, food loops, and practical life on Mars.",
      topics: @[
        SeedTopic(
          title: "First crop that should be mandatory",
          starter: "GreenDome",
          body: "If every outpost must pick one crop for reliability, what should it be and why?",
          replies: @[
            (author: "RootBuilder", body: "Potatoes are forgiving and useful in many meals."),
            (author: "SproutLogic", body: "Leafy greens grow fast and improve crew morale."),
            (author: "WaterLoop", body: "Pick crops that match your recycling system, not just calories.")
          ]
        ),
        SeedTopic(
          title: "Dust storm prep checklist",
          starter: "RedHorizon",
          body: "Sharing our pre-storm routine. Add missing steps before we standardize it.",
          replies: @[
            (author: "HullWatch", body: "Lock external joints and verify spare seals in every rover."),
            (author: "PanelNurse", body: "Angle panels for lowest stress, not max collection."),
            (author: "CalmCircuit", body: "Print laminated check cards so emergency routines stay simple.")
          ]
        ),
        SeedTopic(
          title: "Do we need quiet hours in habitat halls?",
          starter: "ModuleNine",
          body: "The colony is getting crowded. Should we define no-noise hours near sleeping pods?",
          replies: @[
            (author: "SoftBoot", body: "Yes. Clear quiet blocks reduce conflict fast."),
            (author: "NightShift", body: "Add exception tags for maintenance emergencies only."),
            (author: "RedLedger", body: "Post rules near corridor entries so visitors can follow easily.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Planets",
      slug: "jupiter-observers",
      title: "Jupiter Observers",
      description: "Storm tracking, moon missions, and gas giant lore.",
      topics: @[
        SeedTopic(
          title: "Great Red Spot watch log",
          starter: "BandSeeker",
          body: "Track size and color shifts here. Share timestamps and instrument details.",
          replies: @[
            (author: "StripePilot", body: "Saw darker edges this week with medium aperture."),
            (author: "Moonside", body: "Color looked pale in my setup, maybe seeing conditions."),
            (author: "StormGrid", body: "Posting charts helps, but text notes are easier to compare quickly.")
          ]
        ),
        SeedTopic(
          title: "Europa mission supply ideas",
          starter: "IceLander",
          body: "If we stage through Jupiter orbit, what must be pre-positioned for Europa teams?",
          replies: @[
            (author: "CryoLead", body: "Drill spare heads and heater redundancy are non-negotiable."),
            (author: "RelayChain", body: "Communication relay kits should be modular and stackable."),
            (author: "NavPulse", body: "Keep mission kits boring and standardized across crews.")
          ]
        ),
        SeedTopic(
          title: "Favorite Galilean moon for first base",
          starter: "OrbitFork",
          body: "Pick one moon and defend your choice with one practical reason.",
          replies: @[
            (author: "RockAndIce", body: "Ganymede for size and potential resource flexibility."),
            (author: "TidalFan", body: "Europa for science value, even if operations are harder."),
            (author: "ShieldFrame", body: "Callisto for calmer radiation environment.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Planets",
      slug: "saturn-ring",
      title: "Saturn Ring Station",
      description: "Ring science, Titan flights, and outer-system cargo routes.",
      topics: @[
        SeedTopic(
          title: "How would you map ring traffic lanes?",
          starter: "CassiniEcho",
          body: "Assume regular cargo movement between stations. How do we keep lanes predictable?",
          replies: @[
            (author: "LaneKeeper", body: "Fixed windows and strict velocity bands make routing manageable."),
            (author: "IceDust", body: "Mark emergency drift corridors outside standard lanes."),
            (author: "FreightNim", body: "Publish lane updates in plain text before every shift.")
          ]
        ),
        SeedTopic(
          title: "Titan weekend trip thread",
          starter: "MethaneSkies",
          body: "Drop your favorite landing zones and weather notes for short Titan visits.",
          replies: @[
            (author: "OrangeHaze", body: "Western dunes were calm last cycle and easy for landing."),
            (author: "ProbePilot", body: "Bring redundant heaters. Nights feel endless there."),
            (author: "WideStep", body: "Titan hiking photos never look real, in the best way.")
          ]
        ),
        SeedTopic(
          title: "Ring particle art challenge",
          starter: "PixelRing",
          body: "Use telescope captures to make tiny monochrome art posts.",
          replies: @[
            (author: "MonoFrame", body: "Posting mine tonight with a high-contrast crop."),
            (author: "SignalDust", body: "Please include settings so others can reproduce your look."),
            (author: "ArcLamp", body: "This challenge is unexpectedly relaxing after long shifts.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "Off Topic Discussions",
      slug: "station-cafe",
      title: "Station Cafe",
      description: "Crew lounge talk, hobbies, and daily life between missions.",
      topics: @[
        SeedTopic(
          title: "What are you reading this cycle?",
          starter: "PaperMoon",
          body: "Post one book, article, or manual you are reading outside direct mission work.",
          replies: @[
            (author: "DryDock", body: "A history of observatories. It is slow but worth it."),
            (author: "LineCook", body: "Old sci-fi paperbacks with terrible covers and great ideas."),
            (author: "OrbitSnack", body: "Mostly repair manuals, but I count those as reading too.")
          ]
        ),
        SeedTopic(
          title: "Best zero-g coffee setup",
          starter: "BrewSignal",
          body: "Every crew claims theirs is best. Share your simple and reliable coffee method.",
          replies: @[
            (author: "MugLatch", body: "Magnetic mug plus measured pouches keeps cleanup easy."),
            (author: "SteamLoop", body: "Low pressure drip with a clamp. Slow but very consistent."),
            (author: "WarmDeck", body: "The best setup is whichever one survives morning turbulence.")
          ]
        ),
        SeedTopic(
          title: "Favorite maintenance playlist",
          starter: "TorqueTape",
          body: "What do you play during long repair shifts when everyone is tired?",
          replies: @[
            (author: "QuietPulse", body: "Instrumental only. Lyrics distract me while rewiring panels."),
            (author: "RivetKid", body: "Old game soundtracks are perfect for focused work."),
            (author: "SpareParts", body: "Anything steady with no sudden volume spikes.")
          ]
        )
      ],
      emptyTopicCount: 0
    ),
    SeedBoard(
      section: "General Discussions",
      slug: "paging-lab",
      title: "Paging Lab",
      description: "High-volume board for pagination testing.",
      topics: @[],
      emptyTopicCount: 40
    )
  ]
proc main() =
  ## Generates fake forum data for local visual testing.
  let serverSecret = getEnv("NOBBY_SERVER_SECRET", "nobby-dev-secret-change-me")
  let pool = newForumPool("forum.db", 2)
  pool.initSchema()
  pool.initAccountsSchema()
  if pool.listBoards().len > 0:
    echo "Database is not empty. Clear forum.db first, then rerun this script."
    quit(1)
  let seeds = makeSeeds()
  pool.seedPostingAccounts(seeds, serverSecret)
  var clock = models.nowEpoch() - 20'i64 * 24'i64 * 60'i64 * 60'i64
  var boardCount = 0
  var topicCount = 0
  var replyCount = 0
  for boardSeed in seeds:
    let inserted = pool.insertBoardData(boardSeed, clock)
    inc boardCount
    topicCount += inserted.topics
    replyCount += inserted.replies
  echo "Generated fake data."
  echo "Boards: ", boardCount
  echo "Topics: ", topicCount
  echo "Replies: ", replyCount
  echo "Accounts: seeded posting users + Admin(admin@examle.com / hunter2)"
when isMainModule:
  main()
