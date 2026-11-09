--- === SpotifyKnob ===
---
--- Turns a cheap USB volume knob into a Spotify Connect controller with a
--- now-playing card: adaptive glass, cover art, an album-tinted vinyl record,
--- and volume that reaches an actual Connect speaker rather than the Mac's
--- output.
---
--- Built for the Anticater VK-01 but hardware-agnostic -- anything that can be
--- programmed to emit F16-F20 will drive it. See README.md for the knob mapping
--- and the Spotify credential setup.
---
--- Download: https://github.com/agustinlinenberg/spotify-knob

local obj = {}
obj.__index = obj

obj.name     = "SpotifyKnob"
obj.version  = "1.0"
obj.author   = "Agustin Linenberg"
obj.homepage = "https://github.com/agustinlinenberg/spotify-knob"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- SpotifyKnob.connectDevice
--- Variable
--- Substring matched against your Spotify Connect device names. Volume and
--- playback are routed here. Defaults to the currently active device if unset.
obj.connectDevice = nil

--- SpotifyKnob.vinyl
--- Variable
--- Draw the record sliding out from behind the cover art. Default true.
obj.vinyl = true

--- SpotifyKnob.clickable
--- Variable
--- Make the transport controls respond to the mouse. Off by default: skip lives
--- on the knob, and a clickable card swallows clicks underneath it while shown.
obj.clickable = false

--- SpotifyKnob.step
--- Variable
--- Volume points per detent, and the fine step used when Shift is held.
obj.step = 4
obj.fineStep = 1

--- SpotifyKnob.dwell
--- Variable
--- Seconds the card stays on screen after you stop touching the knob.
obj.dwell = 3.4

--- SpotifyKnob.spinRate
--- Variable
--- Fraction of true platter speed the record's highlight appears to travel at.
--- Physically this wants to be near zero -- see the note by VIN_DRIFT.
obj.spinRate = 0.42

local SPOON_PATH = hs.spoons.resourcePath("")
local CACHE_DIR  = os.getenv("HOME") .. "/.cache/spotify-knob/"

require("hs.ipc")             -- enables the `hs` command-line tool

local CONNECT_DEVICE = obj.connectDevice or ""   -- see SpotifyKnob.connectDevice
local STEP           = obj.step
local FINE_STEP      = obj.fineStep
local PUSH_DELAY     = 0.2       -- seconds; batch API writes while the knob spins
local RESYNC_AFTER   = 8         -- seconds idle before a turn re-reads the truth
local HOTKEY         = { { "ctrl", "alt", "cmd" }, "s" }
local BRIDGE         = SPOON_PATH .. "spotify-connect.py"

-- What the knob sends after being reprogrammed. The long-press pair used to be
-- screen brightness, which is the factory default and has nothing to do with
-- anything here -- a third of the input surface on a device bought for music.
local KEY_PRESS = "f16"
local KEY_LEFT  = "f17"
local KEY_RIGHT = "f18"
local KEY_BACK  = "f19"      -- long press + turn left
local KEY_FWD   = "f20"      -- long press + turn right

-- A plain turn is fine, Shift gives the coarse step. Defaults on; the menu
-- toggle overrides it and the choice survives reloads. Written this way rather
-- than `or true` so an explicit false from the menu isn't silently flipped back
-- on at every reload.
local savedFine   = hs.settings.get("spotifyPreferFine")
local preferFine  = (savedFine == nil) and true or savedFine
local vol         = 50
local device      = "?"
local playing     = false
local title       = ""
local artist      = ""
-- Progress is stored as "it was here, at this moment" rather than as a running
-- number, so the clock can be interpolated from it without polling Spotify.
local progressMs  = 0
local durationMs  = 0
local progressAt  = 0
local pendingVol  = nil
local debugging   = false
local menu        = hs.menubar.new()
local pushTimer

-- --- bridge ---------------------------------------------------------------

-- Async so the knob never blocks on an HTTP round-trip.
local function bridge(args, cb)
  hs.task.new(BRIDGE, function(code, out, err)
    if debugging then print(("bridge %s -> %d %s"):format(args[1], code, (out or err or ""):sub(1, 120))) end
    -- Errors go to stderr; pass both so callers can actually report the cause.
    if cb then cb(code, ((out or "") .. (err or "")):gsub("^%s+", "")) end
  end, args):start()
end

-- Batch volume writes: a single turn fires many ticks, and one API call each
-- would be slow and hit rate limits. Send only the latest value once the knob
-- settles.
-- Retry once through a transfer: the usual failure is the speaker having gone
-- to sleep, which drops the active device and 404s every write. Silent failure
-- here is worse than useless -- the knob just feels broken.
local function pushVolume(isRetry)
  if not pendingVol then return end
  local want = pendingVol
  pendingVol = nil

  bridge({ "volume", tostring(want) }, function(code, out)
    if code == 0 then return end
    if isRetry then
      setNotice(CONNECT_DEVICE .. " is not answering")
      return
    end
    bridge({ "transfer", CONNECT_DEVICE }, function(tcode)
      if tcode ~= 0 then
        setNotice("Wake " .. CONNECT_DEVICE .. ", then turn again")
        return
      end
      pendingVol = want
      pushVolume(true)
    end)
  end)
end
pushTimer = hs.timer.delayed.new(PUSH_DELAY, pushVolume)

-- --- on-screen card ---------------------------------------------------------

-- This started as a volume readout and grew into a now-playing card, which
-- changes what it owes you. A pill only had to answer "how loud"; a card has to
-- answer "what is this" as well, and a 28pt thumbnail could not -- at that size
-- a cover is a favicon. So: the artwork is the anchor, the track and artist sit
-- beside it, and the bar underneath does double duty -- it reads out the
-- track's progress until you touch the knob, then becomes the volume for as
-- long as you are moving it. One bar, because two would be clutter and only one
-- of them is ever the thing you are doing.
local HUD_W, HUD_H = 380, 168
local CARD_R       = 20
local PAD          = 18

local ART          = 72                  -- cover art, square
-- 4, not 12. Their sleeve is 8px on 220 -- 3.6% -- and that near-square corner
-- is most of why it reads as a record sleeve at all. At 16.7% ours was the
-- corner radius of an iOS app icon, which is exactly what it looked like.
local ART_R        = 4
-- A record sliding out from behind the sleeve. Their version stacks three
-- circles -- a dark radial body, a conic sheen, and the album art again at 30%
-- as the centre label -- but the disc's centre sits behind the sleeve, so the
-- label is never actually visible. All that reads is the crescent of edge, and
-- that is all this draws. Proportions lifted from their layout: the disc is
-- 92% of the sleeve and its centre is offset 19% of the sleeve to the right.
local VINYL        = obj.vinyl
-- 33 1/3 rpm is 200 degrees a second, and that is genuinely what this turns at.
-- Nothing about the disc itself is visible turning -- a radial body and
-- concentric grooves look identical at every angle, and the label that would
-- give it away sits behind the sleeve -- so what actually rotates is the sheen.
-- Which is the honest answer anyway: at this size a spinning record reads as
-- light sweeping across it, not as a moving object.
local VIN_RPM      = 33 + 1/3
-- Fraction of platter speed the reflection appears to travel at.
--
-- Physically this wants to be near zero: lamp and eye are both fixed, so the
-- specular lobes on a real record barely move while the disc turns underneath.
-- Tried that, and it was correct and useless -- on an actual turntable the
-- rotation is carried by the label, and ours is hidden behind the sleeve, so
-- honouring the physics left nothing on screen that moved at all.
--
-- So this is tuned to be read, not to be right: about one revolution every
-- four seconds. Fast enough that a lobe crosses the visible crescent while you
-- are looking at it, slow enough that it never strobes the way true 33rpm did.
local VIN_DRIFT    = obj.spinRate
local VIN_R        = ART * 0.92 / 2
local VIN_CX       = PAD + ART / 2 + ART * 0.19
local VIN_CY       = PAD + ART / 2
-- Measured from the record's edge, not the sleeve's. The disc protrudes about
-- 11pt past the artwork, so a column set off the sleeve left the title with 5pt
-- of air on one side and 16 everywhere else -- it read as the type crowding the
-- vinyl, because it was.
local COL_X        = 116                 -- text column, right of the record

local BAR_Y        = 104                 -- progress / volume
-- 8, not 4. Every one of their surfaces uses a chunky fully-rounded bar; at 4
-- it reads as a hairline rule that happens to be part-filled rather than as a
-- control showing a position.
local BAR_H        = 8
-- The two time labels are the same width and the gaps either side of the bar
-- match. They did not: the bar sat 4pt from the left label and 28pt from the
-- right one, which reads as the bar being shoved leftwards.
local LBL_W        = 44                  -- worst-case time string, "-59:59"
local BAR_GAP      = 8
-- Volume mode puts a 12pt glyph on the left and "100%" on the right, both far
-- narrower than a time string. Sizing every slot for the worst-case time left
-- the volume bar swimming in space it never used, so the ends are measured per
-- mode instead of assumed. The labels stay pinned to the card edges either way
-- -- it is only the bar that grows into the slack.
local VOL_LEFT_W   = 16
local VOL_RIGHT_W  = 34                  -- fits "100%" and "muted" alike

local ROW_Y        = 128                 -- transport controls
-- The reference sizes its three controls close together rather than making the
-- middle one dominate, and sets them all fairly large.
-- Play/pause is the only one of the three that does anything from here -- the
-- knob owns skip now -- and it is also the only one carrying state. So it keeps
-- its size and its ink, and the other two shrink and step back to read as what
-- they actually are: a legend for what your hands do.
local BTN, BTN_BIG = 19, 28
local BTN_QUIET    = 0.45                -- resting alpha for the two legends
local BTN_GAP      = 52                  -- centre-to-centre
local BADGE        = 18                  -- source mark, on the cover corner
local WAVE         = 16                  -- now-playing mark, top right
-- Four bars rather than one glyph. An equaliser that never moves is a worse
-- lie than no equaliser: the shape's whole meaning is motion, so holding it
-- still says "playing" in a language that reads as "broken". These are not an
-- FFT -- Spotify hands out no audio stream and never will -- but neither are
-- Apple's, or anyone's. Moving bars are the idiom for "sound is coming out",
-- not a claim about spectrum, and that is what this says.
local WAVE_BAR_W   = 2.5
local WAVE_GAP     = 2                   -- 4 bars + 3 gaps == WAVE exactly
local WAVE_X0      = HUD_W - PAD - WAVE
local WAVE_MID     = PAD + (ART - 38) / 2 + 2 + WAVE / 2
local WAVE_MIN     = 3
local WAVE_MAX     = 15
-- 30, not 20. Bars are fine at 20 -- they jump between heights and the eye
-- fills it in -- but a highlight sliding round a circle shows every step it
-- takes, and 20 was visibly notching its way along the crescent.
local WAVE_FPS     = 30
local WAVE_PHASE   = { 0, 1.9, 3.4, 5.1 }
-- Each bar gets its own ceiling. With one shared amplitude all four topped out
-- at the same height on every cycle, which is the tell that a loop is driving
-- them rather than anything real.
local WAVE_AMP     = { 0.78, 1.0, 0.62, 0.88 }
-- A permanent loop is the exact thing Reduce Motion exists to switch off, so it
-- does. Read once at load -- toggling it mid-session is not a thing that needs
-- to be live -- and the bars simply hold a staggered resting shape instead.
local REDUCE_MOTION = (function()
  local out = hs.execute("defaults read com.apple.Accessibility ReduceMotionEnabled 2>/dev/null")
  return (out or ""):match("1") ~= nil
end)()

-- Previous and next live on the knob now, so the card has no control the mouse
-- is the only way to reach -- and a card nobody needs to click should not eat
-- clicks in a 380x168 patch at the bottom of the screen for two seconds after
-- every volume nudge, which is what being mouse-interactive costs. The glyphs
-- stay: the middle one still shows play state, and the outer two name what the
-- knob does. Set this true to get the mouse path back; it is all still here.
local CLICKABLE    = obj.clickable

-- 3.4, up from 2.2. Two seconds is enough to read a volume number and not much
-- else; with a title, an artist, a clock and a record on there it was gone
-- before you had finished looking at it.
local DWELL        = obj.dwell
-- Appearing is not animated, and that is deliberate. The knob is direct
-- physical manipulation fired dozens of times a day; any fade on the way in is
-- a delay sitting exactly where you are already looking, and it reads as lag
-- rather than polish. Leaving is the system retiring on its own, nobody is
-- waiting on it, and a hard cut there would look broken -- so that one fades.
local FADE_OUT     = 0.18
-- How long a turn keeps the bar showing volume before it hands back to
-- progress. Long enough to cover the pause between two nudges.
local VOL_HOLD     = 1.6

-- Menlo for anything numeric. Times and volume change while you watch them, and
-- SF's digits are proportional -- "11" measures 11.9pt against "88" at 16.5pt,
-- so a right-aligned readout visibly twitches at its left edge on every step.
-- Menlo is tabular, so the digits sit still. Monospace as a costume would be
-- wrong; this is measurement, which is what it is for. Title and artist are
-- prose and stay in the system face.
local NUM_FONT     = "Menlo"
local NUM_SIZE     = 11

local BOTTOM_GAP   = 200                 -- clear of the Dock

local ICONS = SPOON_PATH .. "icons/"
local function glyphs(suffix)
  local function g(n) return hs.image.imageFromPath(ICONS .. n .. suffix .. ".svg") end
  return { play = g("play"), pause = g("pause"), muted = g("muted"),
           speaker = g("speaker"), wave = g("wave"), note = g("note"),
           -- A cabinet, not a cone. The volume readout already owns the cone,
           -- and using it twice made "how loud" and "coming out of where" look
           -- like the same fact. Office is a physical box in a room; it should
           -- look like one.
           output = g("output"),
           -- The reference uses double-triangle rewind/forward rather than the
           -- skip-with-a-bar pair. Matching it, and these still drive previous
           -- and next track -- the two glyphs are used interchangeably for that
           -- across most players.
           prev = g("rewind"), next = g("forward"),
           -- A logo is not ink: the mark keeps its own green on either pane.
           source = g("spotify") }
end
local GLYPH_LIGHT_ON_DARK = glyphs("")        -- white marks, for dark glass
local GLYPH_DARK_ON_LIGHT = glyphs("-dark")   -- near-black marks, for light glass

local ART_DIR = CACHE_DIR .. "art/"
hs.fs.mkdir(os.getenv("HOME") .. "/.cache")
hs.fs.mkdir(CACHE_DIR)
hs.fs.mkdir(ART_DIR)

-- Two materials, not one. A single dark tint was the first instinct and it was
-- wrong: over a white document it stops being glass and becomes a grey slab.
-- Apple's own glass does not pick a side either, it swaps material against what
-- is behind it. So does this -- the backdrop is measured, and the card goes
-- light-on-dark or dark-on-light to keep one level of contrast everywhere.
local THEME = {
  dark = {
    -- Thinner than it was. The reference is properly see-through -- the
    -- wallpaper's colour carries right across the pane -- and that is only
    -- affordable because the blur is violent enough that nothing behind
    -- survives as detail. Density was compensating for a blur that, as it
    -- turned out, was not running at all.
    tint  = { red = 0.05, green = 0.05, blue = 0.06, alpha = 0.33 },
    -- The reference's edge is bright the whole way round, not just along the
    -- top: a lit pane, not a lip. The gradient stays, because the top is still
    -- brighter, but the bottom no longer falls away to nothing.
    -- Outer edge separates the card from what is behind it; the inner one is
    -- the light catching the top of the pane. On dark glass a single white ring
    -- does both jobs, so the highlight stays modest.
    rim   = { { white = 1, alpha = 0.80 }, { white = 1, alpha = 0.24 } },
    hl    = { { white = 1, alpha = 0.34 }, { white = 1, alpha = 0.00 } },
    ink   = { white = 1, alpha = 0.96 },
    dim   = { white = 1, alpha = 0.58 },
    track = { white = 1, alpha = 0.22 },
    scrim = { red = 0, green = 0, blue = 0, alpha = 0.55 },
    marks = GLYPH_LIGHT_ON_DARK,
    lift  = 0.86,        -- accent brightness that reads on a dark pane
    -- Where the bar lands when the cover is greyscale and has no hue to give.
    -- Plain ink was too heavy: the bar stopped being an accent and became the
    -- loudest thing on the card.
    bar   = { white = 1, alpha = 0.88 },
  },
  light = {
    -- Light glass carries a little more tint than dark. White ink on a dark
    -- pane survives almost anything behind it; dark ink on a light pane needs
    -- the pane to actually stay light.
    tint  = { red = 1, green = 1, blue = 1, alpha = 0.36 },
    -- Two edges, because one cannot do it. The outer ring is dark the whole way
    -- round -- a white ring is invisible against a white document, which is
    -- most of a Mac, and that is why the top of the card kept disappearing. The
    -- inner ring is the white highlight, drawn just inside the dark one so it
    -- reads as light landing on the pane rather than as a border that failed.
    -- Grading the outer ring darker toward the bottom is the pane's own shade.
    rim   = { { red = 0, green = 0, blue = 0, alpha = 0.14 },
              { red = 0, green = 0, blue = 0, alpha = 0.30 } },
    hl    = { { white = 1, alpha = 0.95 }, { white = 1, alpha = 0.00 } },
    ink   = { red = 0.07, green = 0.07, blue = 0.08, alpha = 0.96 },
    -- 0.68, not 0.55: at 0.55 the artist line landed near 3.5:1 on a light
    -- pane, under the 4.5:1 that body text owes you.
    dim   = { red = 0.07, green = 0.07, blue = 0.08, alpha = 0.68 },
    track = { red = 0, green = 0, blue = 0, alpha = 0.16 },
    -- Pausing dims the cover whichever pane it sits on. A white veil on light
    -- glass reads as loading, not paused.
    scrim = { red = 0, green = 0, blue = 0, alpha = 0.32 },
    marks = GLYPH_DARK_ON_LIGHT,
    lift  = 0.62,        -- ...and the same hue has to go darker to survive here
    bar   = { red = 0.30, green = 0.30, blue = 0.32, alpha = 1 },
  },
}

-- Before the first backdrop exists there is nothing to be translucent against,
-- so the card starts near-opaque rather than as a murky window onto nothing.
local TINT_SOLID = { red = 0.04, green = 0.04, blue = 0.045, alpha = 0.92 }

-- Resolution the backdrop is crushed to before being scaled back up.
--
-- This was 13x6, which is one blur pixel per 29x28pt of card -- enough to
-- average an entire paragraph, a divider and the gaps between them into a
-- single flat tone. Over a light page that tone is white, so the glass had
-- nothing left to be transparent *of*: correct arithmetic, dead material.
-- 26x12 is one pixel per ~15pt, which still destroys any glyph -- 12pt text
-- cannot survive being averaged with its own line spacing -- while keeping the
-- block-level structure that makes a pane read as a pane.
local BLUR_W, BLUR_H = 26, 12
local blurCanvas = hs.canvas.new({ x = 0, y = 0, w = BLUR_W, h = BLUR_H })

-- Failures used to arrive as a grey system alert floating somewhere else on
-- screen, which is a strange thing to do when there is a carefully built card
-- already showing the exact subject that failed. They land on the card now, in
-- the artist line, at full ink so they do not read as metadata.
local notice, noticeUntil = nil, 0
local NOTICE_HOLD = 4.5
local showHud

local boundKeys = {}
local bindKnob
local hud, hudTimer, hudScreen, tickTimer
local artURL, artImg, artAccent, artTask
local artIsDark = false
local backdrop
local theme    = THEME.dark
local hovering = false
local volHeldUntil = 0
-- The bar is one element showing two different quantities. Switching between
-- them used to teleport the fill from wherever the track had got to over to
-- wherever the volume sits, which reads as a glitch rather than a change of
-- subject. It travels now. Only the switch is animated -- once it is showing
-- volume, every further detent moves it immediately, because a bar that eased
-- toward the knob would simply feel behind.
local BAR_MORPH = 0.22
local WAVE_IDX
local waveTimer
local vinAngle = 0
-- Its own clock, deliberately not the track's. Driving rotation off elapsed
-- playback meant every resync re-stamped progress from Spotify, and a
-- correction of a few hundred milliseconds snapped the disc by tens of degrees
-- -- which is what looked like the knob yanking the light. This only ever
-- counts wall-clock seconds spent playing, so nothing external can jog it.
-- Declared above placeLight because that function reads it; as a plain local
-- further down it resolved to a nil global and threw on the first detent.
local spinAccum, spinSince = 0, nil
local placeLight   -- defined once the element indices exist

local barShown, barAnim, barTo, barMode = 0, nil, 0, nil
local barX, barW, barToX, barToW = 0, 0, 0, 0
-- Base frames for the transport glyphs, so a press can shrink them and put
-- them back. Filled in when the card is built.
local btnBase = {}

-- hs.canvas only accepts assignment at index <= count+1, so these must be
-- created in order. Named so the ordering can't drift out of sync again.
-- Canvas images are rectangles, so both the card and the cover are rounded by
-- clipping to a rounded rect and releasing the clip afterwards.
-- Sequential by construction rather than a hand-kept list of numbers: canvas
-- refuses any index above count+1, and the grooves alone are twelve of them.
local IDX = 0
local function nextIdx(n) IDX = IDX + (n or 1) return IDX - (n or 1) + 1 end

local RIM        = nextIdx()
local HL         = nextIdx()
local BG_CLIP    = nextIdx()
local BG_IMG     = nextIdx()
local BG_TINT    = nextIdx()
local BG_UNCLIP  = nextIdx()
local VIN_DISC   = nextIdx()
local VIN_SHEEN  = nextIdx()
-- Twelve, from 36% of the radius out to 91%, every 5% -- their spec exactly.
local VIN_GRV_N  = 12
local VIN_GRV    = nextIdx(VIN_GRV_N)
local VIN_LCLIP  = nextIdx()
local VIN_LIGHT  = nextIdx()
local VIN_LIGHT2 = nextIdx()
local VIN_LUNCLIP = nextIdx()
local VIN_RIM    = nextIdx()
local ART_SHADOW = nextIdx()
local ART_CLIP   = nextIdx()
local ART_IMG    = nextIdx()
local ART_PLATE  = nextIdx()
local ART_NOTE   = nextIdx()
local ART_SCRIM  = nextIdx()
local ART_UNCLIP = nextIdx()
local ART_EDGE   = nextIdx()
local BADGE_EL   = nextIdx()
local TITLE      = nextIdx()
local ARTIST     = nextIdx()
local WAVE_A     = nextIdx()
local WAVE_B     = nextIdx()
local WAVE_C     = nextIdx()
local WAVE_D     = nextIdx()
local L_LABEL    = nextIdx()
local L_ICON     = nextIdx()
local R_LABEL    = nextIdx()
local TRACK      = nextIdx()
local FILL       = nextIdx()
local BTN_PREV   = nextIdx()
local BTN_PLAY   = nextIdx()
local BTN_NEXT   = nextIdx()
local OUT_NAME   = nextIdx()
local OUT_ICON   = nextIdx()

-- Everything about the record's light lives here, and nothing outside this
-- function is allowed to touch it. That is the point: the knob calls showHud on
-- every detent, and anything in that path that nudged the highlight would make
-- the record look like it was reacting to your hand. This reads a clock and
-- nothing else -- not the track position, which Spotify keeps correcting, and
-- not a per-frame accumulator, which would stall whenever the card was hidden.
--
-- Two lobes, opposed. A record's grooves are concentric, so they reflect
-- anisotropically: the highlight is never a single spot travelling round, it is
-- a pair on opposite sides. The pair is the realistic part; the speed is not --
-- see VIN_DRIFT.
function placeLight()
  if not (hud and VINYL) then return end
  local now = hs.timer.secondsSinceEpoch()
  if playing and not spinSince then spinSince = now end
  local secs = spinAccum + (spinSince and (now - spinSince) or 0)
  vinAngle = (secs * VIN_RPM * 6 * VIN_DRIFT) % 360
  local rad = math.rad(vinAngle)
  local ox, oy = math.cos(rad) * VIN_R * 0.55, math.sin(rad) * VIN_R * 0.55
  hud[VIN_LIGHT].center  = { x = VIN_CX + ox, y = VIN_CY + oy }
  hud[VIN_LIGHT2].center = { x = VIN_CX - ox, y = VIN_CY - oy }
end

-- --- backdrop -------------------------------------------------------------

-- Where the card sits, in screen coordinates.
local function hudRect(scr)
  local f = (scr or hs.screen.mainScreen()):frame()
  return { x = f.x + (f.w - HUD_W) / 2, y = f.y + f.h - BOTTOM_GAP, w = HUD_W, h = HUD_H }
end

-- Real translucency, the long way round. macOS hands NSVisualEffectView to
-- native apps; a Hammerspoon canvas never gets it, and a webview is no escape
-- either, because backdrop-filter only blurs content inside the page and never
-- the desktop behind the window. So the card photographs whatever is behind it
-- and wears that, blurred, as its own background.
--
-- Captured live rather than cached. Caching was the obvious move and it was
-- wrong: a card this size usually sits over a window, not over wallpaper, and a
-- window scrolls. A stale backdrop paints it with a scene that is no longer
-- there, which looks worse than no glass at all.
--
-- The cost is the screen grab, around 20ms, and it is paid once per gesture --
-- the guard skips it while the card is already up, so a spin never pays it
-- twice. The blur itself is free: crush the image down to a couple of dozen
-- pixels and let the scaler smooth it on the way back up. That is cheaper than
-- any real convolution and, at this size, indistinguishable from one.
-- Grab a region of a screen. Deliberately not scr:snapshot(rect): that form
-- returns nil outright on some displays -- the built-in panel here is one --
-- while the whole-screen form works everywhere. So take the lot and cut the
-- piece out, in the image's own pixels, which also sidesteps the difference
-- between frame() and fullFrame() and any Retina scale factor.
local function grabRegion(scr, rect)
  local full = scr:snapshot()
  if not full then return nil end
  local sz, ff = full:size(), scr:fullFrame()
  local sx, sy = sz.w / ff.w, sz.h / ff.h
  return full:croppedCopy({ x = (rect.x - ff.x) * sx, y = (rect.y - ff.y) * sy,
                            w = rect.w * sx, h = rect.h * sy })
end

local function captureBackdrop(scr)
  if not hud then return end
  -- Never photograph ourselves. A fade-out still counts as on screen, so cut it
  -- dead first; killing a fade nobody is watching costs nothing.
  if hud:isShowing() then hud:hide(0) end

  local shot = grabRegion(scr, hudRect(scr))
  if not shot then backdrop = nil return end

  -- The blur. hs.image:setSize looks like it would do this and does not -- an
  -- NSImage's size is a display hint, not its bitmap, so setSize leaves every
  -- pixel intact and the "blurred" backdrop comes back pin sharp. Rendering
  -- through a 13x6 canvas genuinely throws the pixels away, and scaling that
  -- back up is the blur. About a 29x crush: anything gentler and words behind
  -- the glass survive as readable smears, which is worse than no glass at all.
  --
  -- The canvas is kept rather than made each time. Building one costs ~150ms;
  -- reusing it costs under a millisecond, and that difference is the whole
  -- reason this is affordable on the way in rather than something to cache.
  blurCanvas[1] = { type = "image", image = shot, imageScaling = "scaleToFit",
                    frame = { x = 0, y = 0, w = BLUR_W, h = BLUR_H } }
  shot = blurCanvas:imageFromCanvas()
  if not shot then backdrop = nil return end

  -- Measure it while it is still tiny: that is the whole backdrop in a couple
  -- of hundred pixels, so a handful of samples describes it as well as a full
  -- scan would.
  local sum, n = 0, 0
  for x = 1, BLUR_W - 1, 2 do
    for y = 1, BLUR_H - 1, 2 do
      local ok, c = pcall(function() return shot:colorAt({ x = x, y = y }) end)
      if ok and c and c.red then
        -- Rec. 709 luma: the eye weights green far above blue, and a flat mean
        -- calls saturated blues bright when they read as dark.
        sum = sum + 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        n = n + 1
      end
    end
  end
  -- Bias towards dark. Dark glass is the safer of the two -- it survives a busy
  -- backdrop that light glass would let bleed through -- so light has to be
  -- clearly earned rather than merely likelier.
  theme = (n > 0 and sum / n > 0.62) and THEME.light or THEME.dark

  -- Left at 13x6; the canvas element scales it up to fill the card, and letting
  -- the compositor do that is what smooths it.
  backdrop = shot
end

-- --- cover art ------------------------------------------------------------

-- One colour, sampled from the cover, and it is allowed exactly one job: the
-- bar. Spotify's own shell works this way -- the artwork supplies the colour and
-- everything around it stays monochrome -- and that is the rule that keeps a
-- card this small from turning into a paint chart.
local function accentFrom(img)
  local sz = img:size()
  local STEPS, BUCKETS = 8, 12
  local weight, acc = {}, {}
  for i = 1, BUCKETS do weight[i] = 0; acc[i] = { r = 0, g = 0, b = 0, n = 0 } end

  -- Vote on hue rather than taking the most vivid pixel. A single neon detail on
  -- an otherwise muted cover wins an argmax outright and hands back a colour
  -- nobody would say the record is; binning by hue and weighting each vote by
  -- saturation times brightness returns the colour the cover actually reads as.
  -- The grid is inset from the edges because covers letterbox and vignette, and
  -- the corners are where the dead black bars live.
  for gx = 1, STEPS do
    for gy = 1, STEPS do
      local ok, c = pcall(function()
        return img:colorAt({ x = math.floor(sz.w * gx / (STEPS + 1)),
                             y = math.floor(sz.h * gy / (STEPS + 1)) })
      end)
      if ok and c and c.red then
        local r, g, b = c.red, c.green, c.blue
        local mx, mn = math.max(r, g, b), math.min(r, g, b)
        local sat = mx > 0 and (mx - mn) / mx or 0
        -- Near-black, near-white and near-grey carry no hue worth voting with.
        if mx > 0.12 and sat > 0.18 then
          local d, h = mx - mn, 0
          if mx == r then h = ((g - b) / d) % 6
          elseif mx == g then h = (b - r) / d + 2
          else h = (r - g) / d + 4 end
          local idx = math.floor((h * 60) / (360 / BUCKETS)) % BUCKETS + 1
          local w = sat * mx
          weight[idx] = weight[idx] + w
          local a = acc[idx]
          a.r, a.g, a.b, a.n = a.r + r * w, a.g + g * w, a.b + b * w, a.n + w
        end
      end
    end
  end

  -- Overall lightness, not just hue. A sleeve that is mostly black but has one
  -- bright detail still wins a hue vote, so the record came out tinted from a
  -- corner of the artwork nobody would call its colour. A dark cover presses a
  -- black record, which is also what the pressing plant would have done.
  local lum, ln = 0, 0
  for gx = 1, STEPS do
    for gy = 1, STEPS do
      local ok, c = pcall(function()
        return img:colorAt({ x = math.floor(sz.w * gx / (STEPS + 1)),
                             y = math.floor(sz.h * gy / (STEPS + 1)) })
      end)
      if ok and c and c.red then
        lum = lum + 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        ln = ln + 1
      end
    end
  end
  artIsDark = ln > 0 and (lum / ln) < 0.24

  local bi, bw = nil, 0
  for i = 1, BUCKETS do if weight[i] > bw then bi, bw = i, weight[i] end end

  -- A genuinely greyscale cover has no accent to give. Returning nil so the
  -- caller falls back to plain ink is the honest answer; inventing a hue would
  -- be decoration pretending to be data.
  if not bi or bw < 0.6 then return nil end

  -- Normalised to full brightness and kept that way. Which direction the colour
  -- then has to move depends on the pane it lands on, and that is not known
  -- here -- the theme applies its own lift at paint time.
  local a = acc[bi]
  local mx = math.max(a.r, a.g, a.b) / a.n
  return { a.r / a.n / mx, a.g / a.n / mx, a.b / a.n / mx }
end

-- Album art is mastered for a 640px square, not for a 4pt bar, so a literal
-- sample is regularly too dark to see on glass or too pale to see on white.
-- `lift` is where the theme says which problem it has.
local function accentFor(th)
  if not artAccent then return th.bar end
  local l = th.lift
  local r, g, b = artAccent[1] * l, artAccent[2] * l, artAccent[3] * l
  -- Push away from the grey axis too; averaged hues drift towards mud.
  local avg, boost = (r + g + b) / 3, 1.25
  return { red   = math.max(0, math.min(1, avg + (r - avg) * boost)),
           green = math.max(0, math.min(1, avg + (g - avg) * boost)),
           blue  = math.max(0, math.min(1, avg + (b - avg) * boost)),
           alpha = 1 }
end

-- Spotify's art URLs end in a content hash, which makes a perfect cache key:
-- the same cover is fetched once, ever.
local function artPath(url) return ART_DIR .. (url:match("([^/]+)$") or "art") .. ".jpg" end

local function loadArt(url, onReady)
  url = url or ""
  if url == artURL then return end
  artURL = url

  if url == "" then
    artImg, artAccent = nil, nil
    if onReady then onReady() end
    return
  end

  local path = artPath(url)
  local function adopt()
    local img = hs.image.imageFromPath(path)
    if not img then return end
    artImg, artAccent = img, accentFrom(img)
    if onReady then onReady() end
  end

  if hs.fs.attributes(path) then adopt() return end

  -- Fetched off-thread. A cover is never worth making the knob wait, so the
  -- card draws immediately without it and picks it up when it lands.
  if artTask then artTask:terminate() end
  artTask = hs.task.new("/usr/bin/curl", function(code) if code == 0 then adopt() end end,
                        { "-sfL", "--max-time", "5", "-o", path, url })
  artTask:start()
end

-- --- the card -------------------------------------------------------------

-- Spotify serves podcasts as well as tracks, and a long episode overflowed a
-- label sized for "-5:24" -- the digits ran out of the slot rather than
-- truncating anywhere visible. Full h:mm:ss does not fix it either: "-1:00:00"
-- is 53pt against a 48pt slot, and widening the labels enough to hold it would
-- take 16pt off the bar permanently to serve the rare case. So past an hour it
-- switches to "1h04". Seconds on a two-hour episode are noise, and the longest
-- string this can ever produce is five characters.
local function clock(ms)
  if not ms or ms < 0 then ms = 0 end
  local s = math.floor(ms / 1000)
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  if h > 0 then return ("%dh%02d"):format(h, m) end
  return ("%d:%02d"):format(m, s % 60)
end

-- Elapsed time is interpolated, not polled. Spotify is asked for the truth only
-- when something else already needed a round-trip; between those, the clock
-- simply runs, which is what a clock does.
local function elapsedMs()
  if not playing then return progressMs end
  return math.min(durationMs, progressMs + (hs.timer.secondsSinceEpoch() - progressAt) * 1000)
end

-- Rebuilt whole rather than nudged. Setting fillGradientAngle, or a rotation
-- transform, both render correctly through imageFromCanvas and both leave the
-- on-screen canvas untouched -- the window is never marked dirty, so the record
-- sat there turning at a perfectly accurate 33rpm entirely in memory. Assigning
-- the element does invalidate, which is why the bars have been animating all
-- along: they change `frame` every frame, and that counts.
local function sheenAt(angle, action)
  return { type = "circle", action = action or "fill",
           center = { x = VIN_CX, y = VIN_CY }, radius = VIN_R,
           fillGradient = "linear", fillGradientAngle = angle,
           fillGradientColors = { { white = 1, alpha = 0.20 },
                                  { white = 1, alpha = 0.02 },
                                  { white = 1, alpha = 0.13 } } }
end

local function buildHud()
  hud = hs.canvas.new({ x = 0, y = 0, w = HUD_W, h = HUD_H })
  hud:level(hs.canvas.windowLevels.overlay)
  hud:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  hud:canvasMouseEvents(CLICKABLE, CLICKABLE, CLICKABLE, false)
  -- Clicking a transport button should not haul Hammerspoon to the front.
  hud:clickActivating(false)

  -- The specular edge, done as a gradient-filled shape rather than a stroke:
  -- canvas strokes take one flat colour, and a flat rim is the tell that
  -- something is a rounded rectangle rather than a pane of glass. A real edge
  -- catches light along the top and falls away underneath. This draws the
  -- gradient full-bleed and lets everything after it sit one point inside, so
  -- what survives is a 1pt rim, bright up top and nearly gone at the bottom.
  -- Half a point per ring, so the two together come to one. A point each read
  -- as a drawn border rather than as an edge; on a Retina panel half a point is
  -- one device pixel, which is the thinnest a line can honestly be and is what
  -- a hairline is supposed to mean.
  local EDGE = 0.5
  hud[RIM] = { type = "rectangle", action = "fill",
               frame = { x = 0, y = 0, w = HUD_W, h = HUD_H },
               roundedRectRadii = { xRadius = CARD_R, yRadius = CARD_R },
               fillGradient = "linear", fillGradientAngle = 90,
               fillGradientColors = THEME.dark.rim }

  hud[HL] = { type = "rectangle", action = "fill",
              frame = { x = EDGE, y = EDGE, w = HUD_W - EDGE * 2, h = HUD_H - EDGE * 2 },
              roundedRectRadii = { xRadius = CARD_R - EDGE, yRadius = CARD_R - EDGE },
              fillGradient = "linear", fillGradientAngle = 90,
              fillGradientColors = THEME.dark.hl }

  local inset = EDGE * 2
  local innerR = CARD_R - inset
  local inner = { x = inset, y = inset, w = HUD_W - inset * 2, h = HUD_H - inset * 2 }
  hud[BG_CLIP] = { type = "rectangle", action = "clip", frame = inner,
                   roundedRectRadii = { xRadius = innerR, yRadius = innerR } }
  hud[BG_IMG] = { type = "image", action = "skip", image = nil,
                  imageScaling = "scaleToFit", imageAlignment = "center", frame = inner }
  hud[BG_TINT] = { type = "rectangle", action = "fill", frame = inner,
                   roundedRectRadii = { xRadius = innerR, yRadius = innerR },
                   fillColor = TINT_SOLID,
                   trackMouseEnterExit = CLICKABLE, id = "card" }
  hud[BG_UNCLIP] = { type = "resetClip" }

  -- Drawn before the cover, so the sleeve lands on top and crops it to a
  -- crescent. hs.canvas has linear and radial gradients and no conic one, so
  -- the sheen is a linear sweep with a dead band in the middle rather than a
  -- true conic -- across the sliver that actually shows, the two are the same
  -- picture.
  -- A shadow with no offset is a glow, which is how their halo is built -- they
  -- blur a tinted circle behind the disc, and this arrives at the same picture
  -- without needing a blur primitive canvas does not have. Both this and the
  -- sleeve's shadow are tinted from the cover, which is what makes the whole
  -- assembly feel like it belongs to the record rather than sitting near it.
  hud[VIN_DISC] = { type = "circle", action = "skip",
                    withShadow = true,
                    shadow = { blurRadius = 18, offset = { h = 0, w = 0 },
                               color = { red = 0, green = 0, blue = 0, alpha = 0.5 } },
                    center = { x = VIN_CX, y = VIN_CY }, radius = VIN_R,
                    fillGradient = "radial",
                    fillGradientColors = { { red = 0.10, green = 0.10, blue = 0.125, alpha = 1 },
                                           { red = 0.055, green = 0.055, blue = 0.07, alpha = 1 } } }
  hud[VIN_SHEEN] = sheenAt(125, "skip")
  -- Two grooves. Only the outer arcs clear the sleeve, which is the point:
  -- a record is not a black disc, it is a black disc that catches light in
  -- rings, and the rings are the whole reason it reads as vinyl at all.
  -- Alternating light and dark, which is the part that matters: a bright ring
  -- beside a dark one reads as a ridge catching light, where a run of identical
  -- rings just reads as circles drawn on a disc. Their stroke is 0.5 on a 202px
  -- record; ours stays 0.5 rather than scaling down with the disc, because a
  -- hairline cannot go below one device pixel and still exist.
  for i = 1, VIN_GRV_N do
    local frac = (36 + (i - 1) * 5) / 100
    local light = (i % 2 == 1)
    hud[VIN_GRV + i - 1] = {
      type = "circle", action = "skip", strokeWidth = 0.5,
      center = { x = VIN_CX, y = VIN_CY }, radius = VIN_R * frac,
      strokeColor = light and { white = 1, alpha = 0.12 }
                          or { red = 0, green = 0, blue = 0, alpha = 0.18 } }
  end
  -- The same trick as the sleeve's inner hairline, wrapped round the disc: a
  -- thin bright line just inside the outer edge. On the sleeve it turns a flat
  -- image into printed card; here it turns a flat circle into something with a
  -- moulded lip that light is landing on.
  -- The travelling light. Canvas only repaints on positional changes, which is
  -- why three attempts at rotating a gradient advanced the angle perfectly and
  -- drew nothing: the light has to be a thing that moves, not a style that
  -- turns. Wide and faint rather than small and bright -- at 0.72 radius and
  -- 0.22 alpha it read as a spotlight crossing the disc instead of a sheen
  -- sweeping over it. Clipped to the record so it never spills past the rim.
  hud[VIN_LCLIP] = { type = "circle", action = "clip",
                     center = { x = VIN_CX, y = VIN_CY }, radius = VIN_R }
  hud[VIN_LIGHT] = { type = "circle", action = "skip",
                     center = { x = VIN_CX, y = VIN_CY - VIN_R * 0.62 },
                     radius = VIN_R * 0.95,
                     fillGradient = "radial",
                     fillGradientColors = { { white = 1, alpha = 0.14 },
                                            { white = 1, alpha = 0.0 } } }
  hud[VIN_LIGHT2] = { type = "circle", action = "skip",
                      center = { x = VIN_CX, y = VIN_CY + VIN_R * 0.55 },
                      radius = VIN_R * 0.95,
                      fillGradient = "radial",
                      fillGradientColors = { { white = 1, alpha = 0.11 },
                                             { white = 1, alpha = 0.0 } } }
  hud[VIN_LUNCLIP] = { type = "resetClip" }

  hud[VIN_RIM] = { type = "circle", action = "skip", strokeWidth = 1,
                   center = { x = VIN_CX, y = VIN_CY }, radius = VIN_R - 0.5,
                   strokeColor = { white = 1, alpha = 0.22 } }

  -- The sleeve's shadow, carried on its own plate because a shadow drawn on the
  -- clipped artwork would be clipped away with it. Two shadows in their version
  -- -- a wide tinted one and a tight dark one -- collapsed into a single soft
  -- offset cast, which is all that survives at 72pt. Sits after the disc, so
  -- the sleeve correctly shades the record it is covering.
  -- Inset a point, and rounded harder to match. The plate has to be opaque for
  -- anything to cast a shadow, but drawn at the artwork's exact frame the two
  -- curves antialias against each other and the black underneath shows through
  -- as a dark fringe along the edges, worst on the corners and obvious on a
  -- pale sleeve. Shrinking it means the artwork covers it completely and the
  -- shadow, which is soft and offset anyway, loses nothing.
  local shadowFrame = { x = PAD + 1, y = PAD + 1, w = ART - 2, h = ART - 2 }
  hud[ART_SHADOW] = { type = "rectangle", action = "skip", frame = shadowFrame,
                      roundedRectRadii = { xRadius = ART_R + 1, yRadius = ART_R + 1 },
                      fillColor = { red = 0, green = 0, blue = 0, alpha = 1 },
                      withShadow = true,
                      shadow = { blurRadius = 14, offset = { h = -4, w = 0 },
                                 color = { red = 0, green = 0, blue = 0, alpha = 0.45 } } }

  -- Cover art, rounded by clipping. Everything between the clip and the unclip
  -- is confined to the rounded square.
  hud[ART_CLIP] = { type = "rectangle", action = "clip", frame = artFrame,
                    roundedRectRadii = { xRadius = ART_R, yRadius = ART_R } }
  hud[ART_IMG] = { type = "image", action = "skip", image = nil,
                   imageScaling = "scaleToFit", imageAlignment = "center", frame = artFrame }
  -- Paused reads as the cover going dim with a mark over it, rather than as a
  -- separate icon somewhere else. One slot, both signals.
  hud[ART_PLATE] = { type = "rectangle", action = "skip", frame = artFrame,
                     fillColor = THEME.dark.track }
  hud[ART_NOTE] = { type = "image", action = "skip", image = GLYPH_LIGHT_ON_DARK.note,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = PAD + (ART - 26) / 2, y = PAD + (ART - 26) / 2,
                              w = 26, h = 26 } }
  hud[ART_SCRIM] = { type = "rectangle", action = "skip", frame = artFrame,
                     fillColor = THEME.dark.scrim }
  hud[ART_UNCLIP] = { type = "resetClip" }
  -- A hairline drawn just inside the sleeve's own edge. This is the detail that
  -- does the most work in their version and the easiest to miss: printed card
  -- catches light along its cut edge, and without it the artwork reads as an
  -- image pasted onto the card rather than as a physical sleeve lying on it.
  -- Inset half a point so the stroke lands inside the artwork, not on its rim.
  hud[ART_EDGE] = { type = "rectangle", action = "skip", strokeWidth = 1,
                    frame = { x = PAD + 0.5, y = PAD + 0.5, w = ART - 1, h = ART - 1 },
                    roundedRectRadii = { xRadius = ART_R, yRadius = ART_R },
                    strokeColor = { white = 1, alpha = 0.20 } }
  -- The source mark, sitting on the cover's bottom-left corner exactly as in
  -- the reference. Outside the clip, so it keeps its own round edge rather than
  -- being cut by the cover's.
  hud[BADGE_EL] = { type = "image", action = "skip", image = GLYPH_LIGHT_ON_DARK.source,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = PAD + 3, y = PAD + ART - BADGE - 3, w = BADGE, h = BADGE } }

  -- The text block is centred against the cover rather than hung from the top
  -- of the card: two lines beside a 72pt square read as top-heavy otherwise.
  -- Title is the system bold face. "SF Pro Text Semibold" does not resolve --
  -- it silently falls back and the title comes out the same weight as the
  -- artist -- but the descriptor behind defaultFonts.boldSystem does.
  local BOLD = hs.styledtext.defaultFonts.boldSystem.name
  local blockTop = PAD + (ART - 38) / 2
  -- Both lines stop short of the waveform mark. Only the title did, so a long
  -- artist ran 24pt further right and slid underneath the glyph -- which is
  -- exactly what a four-name credit list does.
  local TEXT_W = HUD_W - COL_X - PAD - WAVE - 8
  hud[TITLE] = { type = "text", text = "", textSize = 14.5, textFont = BOLD,
                 textColor = THEME.dark.ink, textLineBreak = "truncateTail",
                 frame = { x = COL_X, y = blockTop, w = TEXT_W, h = 20 } }
  hud[ARTIST] = { type = "text", text = "", textSize = 12.5,
                  textColor = THEME.dark.dim, textLineBreak = "truncateTail",
                  frame = { x = COL_X, y = blockTop + 21, w = TEXT_W, h = 17 } }
  -- Top-right, level with the title, as in the reference. Hidden entirely when
  -- nothing is playing -- a still equaliser is exactly the state this is meant
  -- to avoid.
  WAVE_IDX = { WAVE_A, WAVE_B, WAVE_C, WAVE_D }
  for i, idx in ipairs(WAVE_IDX) do
    hud[idx] = { type = "rectangle", action = "skip",
                 roundedRectRadii = { xRadius = WAVE_BAR_W / 2, yRadius = WAVE_BAR_W / 2 },
                 fillColor = THEME.dark.ink,
                 frame = { x = WAVE_X0 + (i - 1) * (WAVE_BAR_W + WAVE_GAP),
                           y = WAVE_MID - WAVE_MIN / 2, w = WAVE_BAR_W, h = WAVE_MIN } }
  end

  hud[L_LABEL] = { type = "text", text = "", textSize = NUM_SIZE, textFont = NUM_FONT,
                   textColor = THEME.dark.dim,
                   frame = { x = PAD, y = BAR_Y - 3, w = LBL_W, h = 14 } }
  -- Same size as the output glyph: both sit inline with 11pt text, so they are
  -- the same tier and should not differ by a point for no reason.
  hud[L_ICON] = { type = "image", action = "skip", image = GLYPH_LIGHT_ON_DARK.speaker,
                  imageScaling = "scaleProportionally", imageAlignment = "center",
                  frame = { x = PAD, y = BAR_Y - 2, w = 12, h = 12 } }
  hud[R_LABEL] = { type = "text", text = "", textSize = NUM_SIZE, textFont = NUM_FONT,
                   textAlignment = "right", textColor = THEME.dark.dim,
                   frame = { x = HUD_W - PAD - LBL_W, y = BAR_Y - 3, w = LBL_W, h = 14 } }

  hud[TRACK] = { type = "rectangle", action = "fill",
                 roundedRectRadii = { xRadius = BAR_H / 2, yRadius = BAR_H / 2 },
                 fillColor = THEME.dark.track,
                 frame = { x = PAD + LBL_W + BAR_GAP, y = BAR_Y,
                           w = HUD_W - 2 * (PAD + LBL_W + BAR_GAP), h = BAR_H } }
  hud[FILL] = { type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = BAR_H / 2, yRadius = BAR_H / 2 },
                fillColor = THEME.dark.ink,
                frame = { x = PAD + LBL_W + BAR_GAP, y = BAR_Y, w = BAR_H, h = BAR_H } }

  local mid = HUD_W / 2
  hud[BTN_PREV] = { type = "image", image = GLYPH_LIGHT_ON_DARK.prev,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = mid - BTN_GAP - BTN / 2, y = ROW_Y + 5, w = BTN, h = BTN },
                    imageAlpha = BTN_QUIET,
                    trackMouseUp = CLICKABLE, trackMouseDown = CLICKABLE,
                    trackMouseEnterExit = CLICKABLE, id = "prev" }
  hud[BTN_PLAY] = { type = "image", image = GLYPH_LIGHT_ON_DARK.pause,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = mid - BTN_BIG / 2, y = ROW_Y, w = BTN_BIG, h = BTN_BIG },
                    imageAlpha = 0.95,
                    trackMouseUp = CLICKABLE, trackMouseDown = CLICKABLE,
                    trackMouseEnterExit = CLICKABLE, id = "play" }
  hud[BTN_NEXT] = { type = "image", image = GLYPH_LIGHT_ON_DARK.next,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = mid + BTN_GAP - BTN / 2, y = ROW_Y + 5, w = BTN, h = BTN },
                    imageAlpha = BTN_QUIET,
                    trackMouseUp = CLICKABLE, trackMouseDown = CLICKABLE,
                    trackMouseEnterExit = CLICKABLE, id = "next" }

  -- Where playback is going, at the right end of the transport row -- the slot
  -- their players give to output routing. This was dropped back when the thing
  -- was a 44pt pill and there was genuinely nowhere to put it; there is room
  -- now, and "which speaker is this coming out of" is worth a glance.
  -- Both derived from one centre line and one gap, rather than each nudged into
  -- place by hand. The hand-placed version left 2pt between the name and the
  -- glyph, which is not a gap -- it reads as the two having collided.
  local OUT_ICON_W, OUT_GAP, OUT_TXT_H = 12, 6, 14
  local OUT_MID  = ROW_Y + 7 + OUT_TXT_H / 2
  local OUT_RIGHT = HUD_W - PAD
  hud[OUT_NAME] = { type = "text", text = "", textSize = NUM_SIZE, textAlignment = "right",
                    textColor = THEME.dark.dim, textLineBreak = "truncateTail",
                    frame = { x = OUT_RIGHT - OUT_ICON_W - OUT_GAP - 78,
                              y = OUT_MID - OUT_TXT_H / 2, w = 78, h = OUT_TXT_H } }
  hud[OUT_ICON] = { type = "image", action = "skip", image = GLYPH_LIGHT_ON_DARK.output,
                    imageScaling = "scaleProportionally", imageAlignment = "center",
                    frame = { x = OUT_RIGHT - OUT_ICON_W, y = OUT_MID - OUT_ICON_W / 2,
                              w = OUT_ICON_W, h = OUT_ICON_W } }

  btnBase = { prev = hud[BTN_PREV].frame, play = hud[BTN_PLAY].frame,
              next = hud[BTN_NEXT].frame }

  hudTimer = hs.timer.delayed.new(DWELL, function()
    -- Buttons you cannot reach are decoration, so the countdown pauses while
    -- the pointer is on the card.
    if hovering then hudTimer:start() return end
    -- A message you did not get time to read is not a message.
    if notice and hs.timer.secondsSinceEpoch() < noticeUntil then hudTimer:start() return end
    if hud then hud:hide(FADE_OUT) end
    if tickTimer then tickTimer:stop() end
    if waveTimer then waveTimer:stop() end
  end)

  -- Half a second, not one: a clock ticked exactly on the second drifts visibly
  -- against the real one, and this is cheap -- two element writes.
  tickTimer = hs.timer.new(0.5, function()
    if hud and hud:isShowing() then paintBar() end
  end)

  -- Three sine waves at different phases and speeds, so the four bars never
  -- fall into a pattern you can watch repeating. Runs only while the card is up
  -- and something is playing, which is the only time it is on screen at all.
  waveTimer = hs.timer.new(1 / WAVE_FPS, function()
    if not (hud and hud:isShowing() and playing) then return end
    local t = hs.timer.secondsSinceEpoch()

    placeLight()

    for i, idx in ipairs(WAVE_IDX) do
      local u = 0.5 + 0.5 * math.sin(t * (5.5 + i * 0.7) + WAVE_PHASE[i])
      local h = WAVE_MIN + u * (WAVE_MAX - WAVE_MIN) * WAVE_AMP[i]
      hud[idx].frame = { x = WAVE_X0 + (i - 1) * (WAVE_BAR_W + WAVE_GAP),
                         y = WAVE_MID - h / 2, w = WAVE_BAR_W, h = h }
    end
  end)

  -- A control that does nothing until the network answers does not feel like a
  -- control. The glyph shrinks and dims under the pointer the instant the
  -- button goes down, which is the whole of the feedback the press needs -- the
  -- actual result arrives when Spotify gets round to it.
  local ELEM = { prev = BTN_PREV, play = BTN_PLAY, next = BTN_NEXT }
  local function press(id, down)
    local el, base = ELEM[id], btnBase[id]
    if not el or not base then return end
    if down then
      local inset = base.w * 0.07     -- ~0.86 scale, about the floor for a bare
      hud[el].frame = { x = base.x + inset, y = base.y + inset,
                        w = base.w - inset * 2, h = base.h - inset * 2 }
      hud[el].imageAlpha = 0.6        -- glyph before it stops reading as a press
    else
      hud[el].frame = base
      hud[el].imageAlpha = 0.85
    end
  end

  if CLICKABLE then hud:mouseCallback(function(_, message, id)
    if id == "card" then
      hovering = (message == "mouseEnter")
      return
    end
    -- Entering a button also counts as being on the card. Without this the
    -- card's own exit fires as the pointer crosses onto a control, the dwell
    -- resumes, and the card can retire out from under the click.
    if message == "mouseEnter" then
      hovering = true
      if ELEM[id] then hud[ELEM[id]].imageAlpha = 1 end
      return
    end
    if message == "mouseExit" then
      if ELEM[id] then press(id, false) end
      return
    end
    if message == "mouseDown" then press(id, true) return end
    if message ~= "mouseUp" then return end
    press(id, false)
    if id == "play" then spotifyPlayPause()
    elseif id == "prev" then spotifySkip("prev")
    elseif id == "next" then spotifySkip("next") end
  end) end
end

-- Separate from showHud so a cover that lands mid-dwell can repaint without
-- restarting the countdown -- otherwise a slow fetch silently extends how long
-- the card sits on screen.
function paintArt()
  if not hud then return end

  local hasArt = artImg ~= nil
  hud[ART_IMG].action      = hasArt and "fill" or "skip"
  hud[ART_IMG].image       = artImg
  -- Without a cover the anchor slot was simply a 72pt hole, which reads as a
  -- failure to load rather than as nothing playing. A note on a faint plate
  -- says the slot is doing its job and has nothing to show.
  hud[ART_PLATE].action    = hasArt and "skip" or "fill"
  hud[ART_PLATE].fillColor = theme.track
  hud[ART_NOTE].action     = hasArt and "skip" or "fill"
  hud[ART_NOTE].image      = theme.marks.note
  hud[ART_SCRIM].action    = (hasArt and not playing) and "fill" or "skip"
  hud[ART_SCRIM].fillColor = theme.scrim
  hud[BADGE_EL].action     = hasArt and "fill" or "skip"
  -- Both shadows are tinted from the cover rather than being neutral black.
  -- Theirs uses one navy for the sleeve's shadow and the disc's halo alike, and
  -- that shared colour is what stops the record reading as a grey shape parked
  -- next to the artwork. A greyscale cover gets plain black, same as the bar.
  local a = artAccent
  local function cast(alpha)
    if not a then return { red = 0, green = 0, blue = 0, alpha = alpha } end
    -- Deepened hard: a shadow carries the hue, never the brightness.
    return { red = a[1] * 0.30, green = a[2] * 0.30, blue = a[3] * 0.34, alpha = alpha }
  end
  hud[ART_EDGE].action   = hasArt and "stroke" or "skip"
  hud[ART_SHADOW].action = hasArt and "fill" or "skip"
  -- Lighter than it was. Theirs is barely there on the borders; the inner
  -- hairline is what sells the object, not the shadow shouting underneath it.
  hud[ART_SHADOW].shadow = { blurRadius = 11, offset = { h = -3, w = 0 }, color = cast(0.34) }

  -- No sleeve, no record.
  local vin = VINYL and hasArt
  hud[VIN_DISC].shadow = { blurRadius = 18, offset = { h = 0, w = 0 }, color = cast(0.55) }
  -- Coloured vinyl is translucent; black vinyl is not. So a cover with a hue
  -- presses it into a pressing you can see through -- the card's own glass, and
  -- whatever is behind that, carries on through the disc -- while a greyscale
  -- cover gets the opaque near-black that a standard 180g record actually is.
  -- The hue is the same one the progress bar is using, so the record and the
  -- readout are visibly the same colour rather than two colours that agree.
  if a and not artIsDark then
    local function vinyl(alpha)
      return { red = a[1] * 0.52, green = a[2] * 0.52, blue = a[3] * 0.58, alpha = alpha }
    end
    hud[VIN_DISC].fillGradientColors = { vinyl(0.50), vinyl(0.78) }
  else
    hud[VIN_DISC].fillGradientColors = {
      { red = 0.10, green = 0.10, blue = 0.125, alpha = 1 },
      { red = 0.055, green = 0.055, blue = 0.07, alpha = 1 } }
  end
  hud[VIN_DISC].action  = vin and "fill" or "skip"
  hud[VIN_SHEEN] = sheenAt(vinAngle, vin and "fill" or "skip")
  for i = 0, VIN_GRV_N - 1 do hud[VIN_GRV + i].action = vin and "stroke" or "skip" end
  hud[VIN_RIM].action   = vin and "stroke" or "skip"
  hud[VIN_LCLIP].action = vin and "clip" or "skip"
  hud[VIN_LIGHT].action  = vin and "fill" or "skip"
  hud[VIN_LIGHT2].action = vin and "fill" or "skip"
  -- Bank the seconds when the music stops so the drift resumes where it was
  -- rather than from wherever the clock happens to be.
  if playing then
    if not spinSince then spinSince = hs.timer.secondsSinceEpoch() end
  elseif spinSince then
    spinAccum = spinAccum + (hs.timer.secondsSinceEpoch() - spinSince)
    spinSince = nil
  end
  -- The mark means "something is coming out of the speakers", so it goes when
  -- nothing is.
  -- Paused settles the bars flat rather than deleting them. The cover dims when
  -- you pause, it does not vanish; the equaliser should read the same way, and
  -- a row that drops to rest is a state change instead of an element going
  -- missing.
  for i, idx in ipairs(WAVE_IDX) do
    hud[idx].action    = "fill"
    hud[idx].fillColor = playing and theme.ink or theme.dim
    if not playing or REDUCE_MOTION then
      local h = REDUCE_MOTION and playing and (WAVE_MIN + WAVE_AMP[i] * 6) or WAVE_MIN
      hud[idx].frame = { x = WAVE_X0 + (i - 1) * (WAVE_BAR_W + WAVE_GAP),
                         y = WAVE_MID - h / 2, w = WAVE_BAR_W, h = h }
    end
  end

  hud[FILL].fillColor = accentFor(theme)
end

-- Bar, labels and the play glyph, split out so the tick timer can move the
-- clock on without touching anything else.
-- How far the bar reaches, given what is sitting at either end of it.
local function barGeom(mode)
  local lw = (mode == "vol") and VOL_LEFT_W or LBL_W
  local rw = (mode == "vol") and VOL_RIGHT_W or LBL_W
  return PAD + lw + BAR_GAP, HUD_W - PAD * 2 - lw - rw - BAR_GAP * 2
end

-- Floor at the bar height so the fill stays a dot rather than collapsing into a
-- sliver at the low end.
local function drawBar(x, w, frac)
  if not hud then return end
  hud[TRACK].frame = { x = x, y = BAR_Y, w = w, h = BAR_H }
  hud[FILL].frame  = { x = x, y = BAR_Y, w = math.max(BAR_H, w * frac), h = BAR_H }
end

local function easeOut(t) return 1 - (1 - t) ^ 3 end

-- Ends and fill travel on one clock and one curve. They are all expressing the
-- same gesture -- you touched the knob -- so anything that let them arrive
-- separately would read as three things reacting rather than one changing its
-- mind.
-- Retargets rather than restarting: a detent landing mid-flight moves the
-- destination and lets the same run finish on its original clock, so the bar
-- arrives once instead of chasing itself.
local function morphBar(toX, toW, toFrac)
  barToX, barToW, barTo = toX, toW, toFrac
  if barAnim then return end
  local fx, fw, ff = barX, barW, barShown
  local t0 = hs.timer.secondsSinceEpoch()
  barAnim = hs.timer.doEvery(1 / 60, function()
    local t = (hs.timer.secondsSinceEpoch() - t0) / BAR_MORPH
    if t >= 1 or not hud then
      barX, barW, barShown = barToX, barToW, barTo
      drawBar(barX, barW, barShown)
      barAnim:stop() barAnim = nil
      return
    end
    local e = easeOut(t)
    barX     = fx + (barToX - fx) * e
    barW     = fw + (barToW - fw) * e
    barShown = ff + (barTo - ff) * e
    drawBar(barX, barW, barShown)
  end)
end

function paintBar()
  if not hud then return end
  local volMode = hs.timer.secondsSinceEpoch() < volHeldUntil
  local mode, frac

  if volMode then
    local muted = vol < 1
    mode, frac = "vol", vol / 100
    hud[L_LABEL].text  = ""
    hud[L_ICON].action = "fill"
    hud[L_ICON].image  = muted and theme.marks.muted or theme.marks.speaker
    hud[R_LABEL].text  = muted and "muted" or (math.floor(vol) .. "%")
  else
    local e = elapsedMs()
    mode, frac = "prog", durationMs > 0 and (e / durationMs) or 0
    hud[L_LABEL].text  = clock(e)
    hud[L_ICON].action = "skip"
    -- Counting down, with the minus, the way their floating and menu-bar
    -- players both do. How long is left is the question you actually ask; the
    -- track's total length is trivia you can work out from the other end.
    hud[R_LABEL].text  = "-" .. clock(durationMs - e)
  end

  local gx, gw = barGeom(mode)
  if barMode ~= nil and mode ~= barMode then
    morphBar(gx, gw, frac)               -- changed subject: travel
  elseif barAnim then
    barToX, barToW, barTo = gx, gw, frac -- still travelling: aim at the new value
  else
    barX, barW, barShown = gx, gw, frac
    drawBar(gx, gw, frac)
  end
  barMode = mode

  hud[BTN_PLAY].image = playing and theme.marks.pause or theme.marks.play
end

function showHud()
  if not hud then buildHud() end

  -- Repositioning is a window move, and a spin calls this on every detent. Only
  -- move the card when it is coming back from hidden or you have changed
  -- screens; re-placing it mid-spin is wasted work that can jitter it a
  -- subpixel while you are staring straight at it.
  local scr = hs.screen.mainScreen()
  if scr:id() ~= hudScreen or not hud:isShowing() then
    hud:frame(hudRect(scr))
    hudScreen = scr:id()
    -- Coming back from hidden is the one moment the glass can be re-shot
    -- without catching the card in its own photograph.
    captureBackdrop(scr)
  end

  -- Glass only once there is something to be glass against.
  hud[BG_IMG].action     = backdrop and "fill" or "skip"
  hud[BG_IMG].image      = backdrop
  hud[BG_TINT].fillColor = backdrop and theme.tint or TINT_SOLID
  hud[RIM].fillGradientColors = backdrop and theme.rim or THEME.dark.rim
  hud[HL].fillGradientColors  = backdrop and theme.hl or THEME.dark.hl

  hud[TITLE].textColor   = theme.ink
  hud[ARTIST].textColor  = theme.dim
  hud[L_LABEL].textColor = theme.dim
  hud[R_LABEL].textColor = theme.dim
  hud[TRACK].fillColor   = theme.track
  hud[BTN_PREV].image    = theme.marks.prev
  hud[BTN_NEXT].image    = theme.marks.next
  -- Only worth showing once it is known, and never as the placeholder.
  local known = device ~= "" and device ~= "?"
  hud[OUT_NAME].text      = known and device or ""
  hud[OUT_NAME].textColor = theme.dim
  hud[OUT_ICON].action    = known and "fill" or "skip"
  hud[OUT_ICON].image     = theme.marks.output

  hud[TITLE].text = title ~= "" and title or "Nothing playing"
  local live = notice and hs.timer.secondsSinceEpoch() < noticeUntil
  hud[ARTIST].text      = live and notice or artist
  hud[ARTIST].textColor = live and theme.ink or theme.dim

  paintArt()
  paintBar()

  -- Cleared on every show. mouseExit does not fire for a window that vanished
  -- under the pointer, so a card hidden while hovered would latch `hovering`
  -- true and then never hide again. A genuine hover re-asserts itself on the
  -- next pointer move.
  hovering = false

  -- Put the light where the clock says it should be before the card is shown.
  -- Without this it holds its last position until the next tick, and since the
  -- first show also pays for the backdrop grab, the two together read as the
  -- highlight stuttering exactly when you touch the knob.
  placeLight()

  hud:show()
  hudTimer:start()
  -- Nothing to tick, and nothing to bounce, when playback is stopped.
  if tickTimer then if playing then tickTimer:start() else tickTimer:stop() end end
  if waveTimer then
    if playing and not REDUCE_MOTION then waveTimer:start() else waveTimer:stop() end
  end
end


local function setNotice(msg)
  notice, noticeUntil = msg, hs.timer.secondsSinceEpoch() + NOTICE_HOLD
  showHud()
end

function spotifyShowHud() showHud() end
function spotifyPrewarm()
  if not hud then buildHud() end
  local scr = hs.screen.mainScreen()
  hud:frame(hudRect(scr))
  hudScreen = scr:id()
  -- The very first grab is the slow one -- around 55ms against 20ms warm -- so
  -- spend it here at load rather than on the first turn of the knob.
  captureBackdrop(scr)
end
function spotifyHudInfo()
  if not hud then return "hud is nil" end
  return ("elements=%d theme=%s art=%s spin=%.0f wave=%s sheen=%s title=%q")
    :format(#hud, theme == THEME.light and "light" or "dark",
            tostring(artImg ~= nil), vinAngle,
            tostring(waveTimer and waveTimer:running()),
            tostring(hud[VIN_SHEEN].action), hud[TITLE].text)
end

local function drawMenu()
  if menu then menu:setTitle("🎵" .. math.floor(vol)) end
end

-- The HUD is feedback for a deliberate knob action, so background refreshes
-- update the menubar only -- otherwise every resync flashes it unprompted.
local function draw()
  drawMenu()
  showHud()
end

local lastSync = 0
local function refreshState(cb)
  bridge({ "state" }, function(code, out)
    local ok, s = pcall(hs.json.decode, out)
    if code == 0 and ok and type(s) == "table" then
      -- Spotify sometimes hands back a speaker's raw ID where its name should
      -- be, a 32-plus character hex blob, which is not a label anyone can use.
      -- When that happens, prefer the name that was configured.
      local dev = s.device or ""
      if dev:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+$") then
        dev = CONNECT_DEVICE ~= "" and CONNECT_DEVICE or "Speaker"
      end
      device   = (dev ~= "" and dev) or "?"
      title    = s.title  or ""
      artist   = s.artist or ""
      playing  = s.playing == true
      durationMs = s.duration or 0
      progressMs = s.progress or 0
      -- Stamp when the reading was taken so the clock can run from it.
      progressAt = hs.timer.secondsSinceEpoch()
      -- Never clobber a spin in flight: pendingVol means the knob is ahead of
      -- the server, and adopting the server's number would yank it backwards
      -- mid-gesture.
      if s.volume and not pendingVol then vol = s.volume end
      -- Fetches only when the URL actually changed, and repaints in place if
      -- the card happens to still be on screen when the cover lands.
      loadArt(s.art, function() if hud and hud:isShowing() then paintArt() end end)
      -- A good read means whatever went wrong is over.
      if code == 0 then notice = nil end
      lastSync = progressAt
    end
    drawMenu()
    if cb then cb() end
  end)
end

-- One gesture, one track.
--
-- Volume wants every detent -- that is the whole point of a knob. Skip does
-- not: a long-press-and-turn is a single intention, but the encoder reports it
-- as five or six clicks, so the naive binding walked back five or six tracks
-- and left you somewhere you had never been. Forward hid it, because landing on
-- something new is plausible either way; backwards it was obvious.
--
-- Leading edge, not trailing: the first detent acts immediately and the rest of
-- the rotation is swallowed. Waiting for the turn to finish would be more
-- literal and would feel broken, since the gesture is over by the time your
-- hand stops. The window only has to outlast the gap between detents.
local SKIP_LOCKOUT = 0.5
local lastSkipAt, skipsSwallowed = 0, 0

-- Skip is fire-and-forget at the API, so the card has nothing to show until a
-- re-read lands. Spotify needs a moment to actually change track before it will
-- report the new one.
function spotifySkip(dir)
  local now = hs.timer.secondsSinceEpoch()
  if now - lastSkipAt < SKIP_LOCKOUT then
    skipsSwallowed = skipsSwallowed + 1
    return
  end
  lastSkipAt = now

  -- Show it immediately. The skip is the one gesture where seeing the result is
  -- the entire point, and it was the only one that did not raise the card --
  -- it waited for the re-read and then only redrew if the card happened to be
  -- up already. The new title is not known yet, but the position is: a track
  -- change starts at zero, so the bar snaps back and reads as "something
  -- changed" while the name catches up a few hundred milliseconds later.
  progressMs, progressAt = 0, now
  volHeldUntil = 0          -- this is about the track, not the volume
  showHud()

  bridge({ dir == "prev" and "prev" or "next" }, function()
    hs.timer.doAfter(0.45, function()
      refreshState(function() if hud and hud:isShowing() then showHud() end end)
    end)
  end)
end

-- How many extra detents the last gestures threw away. Reading a number well
-- above zero here is the confirmation that the encoder was the problem.
function spotifySkipStats()
  local n = skipsSwallowed
  skipsSwallowed = 0
  return n
end

-- The knob follows whatever device Spotify is already on; this is the explicit
-- "put it back on the good speaker" action, not something the knob needs.
local function moveToSpeaker()
  bridge({ "transfer", CONNECT_DEVICE }, function(code)
    if code ~= 0 then
      setNotice("Could not reach " .. CONNECT_DEVICE)
    end
    -- Success needs no announcement: the card itself is the confirmation, and
    -- it now shows the device it moved to.
    refreshState(function() showHud() end)
  end)
end

-- --- globals for the CLI / scripting --------------------------------------

function spotifyVolumeState() return vol, device, playing end
function spotifyMoveToSpeaker() moveToSpeaker() end
function spotifyRefresh() refreshState() end

-- --- knob turn + press ----------------------------------------------------

-- Optimistic on purpose. Pressing a physical knob has to read as heard the
-- instant it moves, and the Web API round-trip is 100-400ms -- long enough that
-- waiting for it makes the press feel dead and invites a second press. So flip
-- the state locally, draw immediately, and reconcile when the bridge answers.
-- Pass the speaker so the bridge can wake it if Spotify has dropped it.
local function playpause()
  -- Bank the clock before flipping. Elapsed is interpolated from "it was here,
  -- at this moment", so pausing without banking leaves the old stamp in place
  -- and the whole paused stretch gets counted the instant playback resumes --
  -- pause for a minute, come back, and the track has silently skipped a minute.
  progressMs = math.min(durationMs, elapsedMs())
  progressAt = hs.timer.secondsSinceEpoch()

  playing = not playing
  showHud()

  bridge({ "playpause", CONNECT_DEVICE }, function(code, out)
    -- Show what actually failed rather than guessing at a cause.
    if code ~= 0 then
      playing = not playing        -- the toggle never happened; put it back
      showHud()
      -- Reads the same whether the network is down or the token has expired,
              -- and the second one never fixes itself, so name the way out.
              setNotice("Spotify not responding — check auth")
      return
    end
    -- The bridge echoes the resulting state. Adopt it only when the optimistic
    -- guess was wrong -- someone paused from their phone, the device moved --
    -- so the common case never redraws twice.
    local actual = out:match("playing") ~= nil
    if actual ~= playing then
      playing = actual
      showHud()
    end
  end)
end
function spotifyPlayPause() playpause() end

local function applyStep(delta)
  vol = math.max(0, math.min(100, vol + delta))
  pendingVol = vol
  pushTimer:start()   -- restarts the countdown on every tick
  -- Hand the bar over to volume, and keep it there for a beat after you stop
  -- so it does not snap back to progress between two nudges.
  volHeldUntil = hs.timer.secondsSinceEpoch() + VOL_HOLD
  draw()
end

local syncing, queued = false, 0

local function nudge(up)
  -- Shift inverts whichever step size is the current default.
  local shift = hs.eventtap.checkKeyboardModifiers().shift
  local fine  = preferFine ~= (shift == true)
  local delta = (up and 1 or -1) * (fine and FINE_STEP or STEP)

  if debugging then print(("nudge up=%s delta=%d vol=%d"):format(tostring(up), delta, vol)) end

  -- A gesture that starts cold is working from a stale baseline: playback may
  -- have moved to another device, or the volume changed in the Spotify app
  -- since we last looked. Re-read first, queueing whatever ticks land during
  -- the round trip so a fast spin doesn't lose them or stampede the API.
  if syncing then queued = queued + delta return end

  if not pendingVol and hs.timer.secondsSinceEpoch() - lastSync > RESYNC_AFTER then
    syncing, queued = true, delta
    refreshState(function()
      local d = queued
      syncing, queued = false, 0
      applyStep(d)
    end)
    return
  end

  applyStep(delta)
end

-- One detent = one step, so bind the press only: no releasefn, no repeatfn.
-- Auto-repeat would double-count a fast spin.
-- Bound in :start(), never at load. Collected in boundKeys so :bindHotkeys()
-- can release them before installing a different mapping.
function bindKnob(map)
  for _, hk in ipairs(boundKeys) do hk:delete() end
  boundKeys = {}
  local function bind(mods, key, fn)
    if key then boundKeys[#boundKeys + 1] = hs.hotkey.bind(mods, key, fn) end
  end
  bind({}, map.playPause, playpause)
  bind({}, map.prev,      function() spotifySkip("prev") end)
  bind({}, map.next,      function() spotifySkip("next") end)
  bind({}, map.turnDown,  function() nudge(false) end)
  bind({}, map.turnUp,    function() nudge(true) end)
  -- Shift is the coarse/fine modifier, and a bare hotkey will not fire while it
  -- is held, so the shifted turns need their own bindings.
  bind({ "shift" }, map.turnDown, function() nudge(false) end)
  bind({ "shift" }, map.turnUp,   function() nudge(true) end)
  if map.moveToSpeaker then
    boundKeys[#boundKeys + 1] =
      hs.hotkey.bind(map.moveToSpeaker[1], map.moveToSpeaker[2], moveToSpeaker)
  end
end

obj.defaultHotkeys = {
  turnDown = KEY_LEFT, turnUp = KEY_RIGHT, playPause = KEY_PRESS,
  prev = KEY_BACK, next = KEY_FWD, moveToSpeaker = HOTKEY,
}


-- --- misc -----------------------------------------------------------------

function debugEvents()
  debugging = not debugging
  hs.alert.show("debug " .. (debugging and "ON — check console" or "OFF"))
end


-- --- Spoon lifecycle --------------------------------------------------------

local started = false

--- SpotifyKnob:init()
--- Method
--- Called by hs.loadSpoon(). Deliberately empty: a Spoon must not bind keys,
--- start timers or touch the network on load, and everything here does all
--- three. Configure the object, then call :start().
function obj:init()
  return self
end

--- SpotifyKnob:start()
--- Method
--- Binds the knob, builds the card and reads current playback state.
function obj:start()
  if started then return self end
  started = true

  -- Re-read config now rather than at load, so anything set between
  -- loadSpoon() and start() is actually honoured.
  CONNECT_DEVICE = self.connectDevice or ""
  STEP, FINE_STEP = self.step, self.fineStep
  VINYL, CLICKABLE, VIN_DRIFT, DWELL = self.vinyl, self.clickable, self.spinRate, self.dwell

  bindKnob(self.hotkeys or obj.defaultHotkeys)
  hs.urlevent.bind("spotify-move-to-speaker", moveToSpeaker)
  -- Same path as the knob: optimistic, targets the speaker, draws the HUD. The
  -- earlier raw bridge call did none of those three.
  hs.urlevent.bind("spotify-playpause", playpause)

  if menu then
    menu:setMenu(function()
      return {
        { title = "Move playback to " .. CONNECT_DEVICE .. " (now: " .. device .. ")",
          fn = moveToSpeaker },
        { title = "Refresh from Spotify", fn = function() refreshState() end },
        { title = "-" },
        { title = ("Prefer fine volume (%d instead of %d)"):format(FINE_STEP, STEP),
          checked = preferFine,
          fn = function()
            preferFine = not preferFine
            hs.settings.set("spotifyPreferFine", preferFine)
            hs.alert.show("Default step: " .. (preferFine and FINE_STEP or STEP))
          end },
        { title = "-" },
        { title = "Debug events", fn = debugEvents },
        { title = "Reload config", fn = hs.reload },
      }
    end)
    drawMenu()
  end

  -- Seed the real volume/device on load so the first turn isn't working from the
  -- placeholder 50.
  refreshState()

  -- Build the pill and photograph its backdrop up front, so the very first turn
  -- of the knob already comes up as glass instead of a flat slab.
  spotifyPrewarm()

  return self
end

--- SpotifyKnob:stop()
--- Method
--- Tears down timers and hides the card. Hotkeys stay bound; use
--- :bindHotkeys({}) or unload the Spoon to release them.
function obj:stop()
  if not started then return self end
  started = false
  for _, t in ipairs({ hudTimer, tickTimer, waveTimer, pushTimer, barAnim }) do
    if t then pcall(function() t:stop() end) end
  end
  if hud then hud:hide(0) end
  if menu then menu:removeFromMenuBar() end
  return self
end

--- SpotifyKnob:bindHotkeys(mapping)
--- Method
--- Rebinds the knob keys. Keys: turnDown, turnUp, playPause, prev, next,
--- moveToSpeaker. Each value is a {mods, key} pair, as hs.hotkey expects.
---
--- The defaults are F17/F18/F16/F19/F20 because those are what the knob is
--- programmed to emit and nothing else on macOS claims them. Change these only
--- if you reprogram the hardware to match.
function obj:bindHotkeys(mapping)
  self.hotkeys = mapping
  if started then bindKnob(mapping) end
  return self
end

return obj
