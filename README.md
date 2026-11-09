# SpotifyKnob

Turn any programmable volume knob into a Spotify player for your Mac. A
Hammerspoon Spoon that drives Spotify Connect from the knob, with a now playing
card that shows up when you touch it.

I built it for the [Anticater VK-01](https://anticater.com), but nothing here is
specific to that knob. Anything you can program to send F16 through F20 will work.

![the card on light, dark and coloured backdrops](docs/backdrops-strip.png)

*Three backdrops, three records. The card reads what's behind it and picks its
material, so it stays legible on a white doc or a dark desktop. The vinyl and the
progress bar both take their colour from the cover art.*

## What it does

Turn the knob and you change the volume of whatever Connect speaker is playing,
not your Mac's output. That distinction is the whole reason this exists. Press to
play or pause. Long press and turn to skip.

The card shows cover art, title, artist, how far into the track you are, how much
is left, and which speaker it's coming out of. Your keyboard's volume keys keep
working on your Mac, untouched.

## Why the knob needs reprogramming

Out of the box the VK-01 sends SOUND_UP, SOUND_DOWN and MUTE at pid 0. That is
byte for byte what your keyboard sends when you hit the volume keys, so there's no
way to tell them apart at the event level. Intercept those and you hijack the
keyboard too.

So the knob gets reprogrammed to send F16 through F20 instead, which nothing else
on macOS claims. Two inputs, two jobs, no overlap.

## Requirements

macOS with [Hammerspoon](https://www.hammerspoon.org), Python 3 (system Python is
fine), and Spotify Premium. The Premium part isn't a preference, the Web API's
playback endpoints just refuse to work without it.

## Setup

### 1. Spotify credentials

Make an app in the [Spotify developer
dashboard](https://developer.spotify.com/dashboard) and add
`http://127.0.0.1:8888/callback` as a redirect URI.

Credentials go in the macOS Keychain, not in a file:

```bash
security add-generic-password -s spotify-knob -a client_id     -w 'YOUR_ID'
security add-generic-password -s spotify-knob -a client_secret -w 'YOUR_SECRET'
```

Then authorise once:

```bash
~/.hammerspoon/Spoons/SpotifyKnob.spoon/spotify-connect.py auth
```

Your refresh token goes in the Keychain too. Nothing sensitive touches the repo or
your Hammerspoon config.

### 2. Program the knob

Plug it in over USB-C. Most of these knobs will only accept a new mapping while
wired, even if they run over Bluetooth afterwards. In the vendor's config app:

| Gesture | Send |
|---|---|
| Turn left | `F17` |
| Turn right | `F18` |
| Press | `F16` |
| Long press + turn left | `F19` |
| Long press + turn right | `F20` |

Save it to the device. The mapping lives on the knob, so it survives reboots and
works fine over Bluetooth. A factory reset wipes it.

### 3. Install

```bash
git clone https://github.com/agustinlinenberg/spotify-knob
cp -r spotify-knob/SpotifyKnob.spoon ~/.hammerspoon/Spoons/
```

In your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("SpotifyKnob")
spoon.SpotifyKnob.connectDevice = "Office"   -- your speaker's name
spoon.SpotifyKnob:start()
```

## Configuration

| Property | Default | What it does |
|---|---|---|
| `connectDevice` | `nil` | Which speaker to drive. Matched as a substring against your Connect device names, or as a device ID. Leave it unset to follow whatever is currently playing. |
| `deviceLabel` | `nil` | What the card prints when Spotify sends no usable device name. Set this when `connectDevice` is an ID. |
| `step` / `fineStep` | `4` / `1` | Volume points per detent. Holding Shift swaps which one you get. |
| `dwell` | `3.4` | Seconds the card stays up. |
| `vinyl` | `true` | Draw the record behind the cover. |
| `spinRate` | `0.42` | How fast the light travels across the record. See below. |
| `clickable` | `false` | Let the mouse work the transport buttons. Off by default, see below. |

If your hardware sends different keys:

```lua
spoon.SpotifyKnob:bindHotkeys({
  turnDown = {{}, "f17"}, turnUp = {{}, "f18"}, playPause = {{}, "f16"},
  prev = {{}, "f19"}, next = {{}, "f20"},
  moveToSpeaker = {{"ctrl","alt","cmd"}, "s"},
})
```

## Things I got wrong first

**It used to wait for Spotify.** Every press went to the API and sat there for 300
to 500ms before anything moved on screen. Long enough that you assume it didn't
register and press again, which on a play/pause toggle undoes what you just did.
Now the knob answers locally and reconciles with Spotify afterwards.

**It used to fade in.** I thought that was polish. It isn't. This is a physical
control you touch dozens of times a day, and any fade on the way in is just lag
sitting exactly where you're already looking. It appears instantly now. Only the
exit fades, because that's the system leaving on its own and nobody's waiting on
it.

**The record used to spin at the right speed**, which was 33 rpm, and it looked
awful. Real vinyl barely shows rotation: your lamp and your eyes are both fixed,
so the reflection sits still while the disc turns under it. What you actually see
spinning is the label, and the label is hidden behind the sleeve here. Modelling
that faithfully gives you a disc that looks parked. `spinRate` is tuned to be read
rather than to be right, about one turn every four seconds.

**The transport buttons used to be clickable.** Then I moved skip onto the knob
and they had nothing left to do, and a clickable card swallows every click landing
underneath it for as long as it's on screen. They're a legend for your hands now.
Set `clickable = true` if you want the mouse back.

## Limitations

Spotify Premium only. The API has no push either, so the card can only appear when
you touch the knob. It can't announce a track change on its own.

The equaliser bars and the light on the record aren't driven by audio. Spotify
doesn't expose a stream. They mean "sound is coming out of this", the same way
they do everywhere else, and they're not a spectrum analyser.

The blurred backdrop is a screen grab, so Hammerspoon needs Screen Recording
permission. Without it the card falls back to a solid fill.

Some speakers come back from the API with their raw ID sitting in the name field,
so there is no name to match or to show. Run this to see what yours report:

```bash
~/.hammerspoon/Spoons/SpotifyKnob.spoon/spotify-connect.py devices
```

If yours is one of the nameless ones, put its ID in `connectDevice` and the name
you want on screen in `deviceLabel`.

## Third party assets

Icons come from [Phosphor](https://phosphoricons.com), MIT licensed, recoloured to
suit the light and dark materials. Their licence is at
[icons/LICENSE](SpotifyKnob.spoon/icons/LICENSE).

## License

MIT, see [LICENSE](LICENSE).
