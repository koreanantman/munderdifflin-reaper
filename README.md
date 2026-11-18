# Munder Difflin

Small, office-themed tools for sound design in [REAPER](https://www.reaper.fm).
Interoffice memos, rubber stamps, binders on a shelf and a rotary phone at the front desk.

| Tool | What it does |
|---|---|
| **Reception** | The front desk. Dial 1-4 to open a tool, 5-9 for your own custom dials, 0 for the operator. |
| **Shredder** | Feed it audio, get random scraps back: random slices with pitch, speed, gain and pan automation. Good for happy accidents. |
| **Stapler** | Lines up the first transient of every selected layer, with an optional offset. |
| **Copier** | Copies audio into MIDI. Five modes: ALL, CHORDS, MELODY, BASS, HITS. |
| **Binder** | Files track templates, FX chains and audio into binders, tabs and sections. Drag them straight onto tracks. |
| **Munder Difflin** | The business card. Credits, orientation, and settings shared by every tool. |

## Install (ReaPack)

1. In REAPER: **Extensions > ReaPack > Import repositories...**
2. Paste:
   ```
   https://github.com/koreanantman/munderdifflin-reaper/raw/main/index.xml
   ```
3. **Extensions > ReaPack > Browse packages**, search **Munder Difflin**, install.

All tools install together into one folder (Reception opens the others from there).

### Tip
Bind **Reception** to a key. When REAPER asks what to do with the already running
instance, choose **Terminate instances** and **Remember my answer**. The same key then
opens and closes the front desk.

## Requirements
- REAPER 6 or newer
- Optional: [SWS](https://www.sws-extension.org) (in-place audio preview in Binder, clipboard for custom dials)
- Optional: [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) (borderless Reception, folder picker)

## Credits
Byungkyu Lee, Assistant to the Regional Manager.

Built with Claude. I mostly said "make it bigger."

*A fan-made parody. Not affiliated with or endorsed by NBC, Universal or The Office.*

## License
[MIT](LICENSE)
