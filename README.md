# FastReader Plugin for KOReader

A powerful RSVP (Rapid Serial Visual Presentation) plugin that enables speed reading with advanced features for KOReader.

## Features

- Tap-to-Launch RSVP: Tap a word to start RSVP reading from that word
- Tap to Pause/Play: Tap the screen to pause, tap again to continue; long press while paused to stop
- Resume Reading: Automatically remembers your last reading position on each page
- Flexible Speed Control: Adjustable reading speed from 50 to 1000 WPM
- Multi-Word Preview: Display multiple words simultaneously (1-10 words configurable)
- Pause on Punctuation: Shows punctuation and holds words ending in it longer (adjustable)
- Font and Size Selection: Pick any font from the book font list and set the RSVP text size
- Optimal View Point Alignment: Optionally anchor each word on a focus crosshair for faster fixation
- Fixed-Width Display: Stable reading widget that doesn't "jump" between words
- Position Tracking: Visual indicator shows reading progress when resuming
- Seamless Page Transitions: Automatically continues to next page when reaching end

## Screenshots

### RSVP Reading Widget
![RSVP Widget](rsvp.gif)
Reading on 400 words per second 

### Settings Menu
![Settings Menu](settings.png)

## Installation

1. Copy the repo contents (or just `main.lua` and `_meta.lua`) to `fastreader.koplugin` folder in your KOReader plugins directory
2. Restart KOReader
3. Enable the plugin in Settings → More Tools -> Plugins → FastReader

## Usage

### Quick Start
1. **Enable Tap-to-Launch**: Settings → FastReader → "Tap on Text to Launch RSVP"
2. **Set your speed**: Settings → FastReader → "RSVP Speed"
3. *(Optional)* Enable or disable the "Optimal Alignment (OVP)" toggle to choose between centered words and crosshair alignment
4. **Tap on any word** to start speed reading from that word
5. **Tap** to pause, **tap** again to continue
6. **Long press while paused** to stop

### Manual Start
- Go to Settings → FastReader → "Start/Stop RSVP"
- Or use the assigned gesture if configured

### Controls During Reading
- **Tap anywhere** to pause; tap again to continue
- **Long press while paused** to stop and return to normal reading
- **Menu/Back button** to stop RSVP at any time
- **Press (d-pad/keyboard)** to pause/continue

## Settings

### Main Settings
- **Start/Stop RSVP**: Manual control for RSVP reading
- **Tap on Text to Launch RSVP**: Enable/disable tap-to-start functionality
- **Show Reading Position**: Toggle position indicator when resuming
- **Preview Words**: Set number of words to display (1-10)
- **Optimal Alignment (OVP)**: Align words around the focus crosshair (monospace) or center them with standard spacing
- **Pause on Punctuation**: Show punctuation and hold words ending in `. , ; : ! ? … —` longer. Spaced-out ellipses (`wait . . .`) are grouped with their word. Abbreviations such as `Mr.` also pause
- **Punctuation Pause**: How much longer those words stay on screen (1.0-4.0×, default 1.5×)
- **Font**: Font for the RSVP widget. Lists the same fonts as the book font menu, plus Default (monospace with OVP on, the UI font with OVP off). Thin or light fonts can look ragged while words are playing on e-ink, and clean when paused
- **Font Size**: Size of the current word (16-72, default 28). Preview words are slightly smaller and the widget grows to fit
- **RSVP Speed**: Comprehensive speed control options

### Speed Presets
- **100 WPM**: Very slow (beginners)
- **150 WPM**: Slow (comfortable reading)
- **200 WPM**: Normal (average reading speed)
- **250 WPM**: Fast (experienced readers)
- **300 WPM**: Very fast (advanced users)
- **400 WPM**: Extreme (speed reading experts)
- **500 WPM**: Ultra fast (maximum speed)

## Tips for Effective Speed Reading

1. **Start Slow**: Begin with 150-200 WPM and gradually increase
2. **Focus on Comprehension**: Speed is useless without understanding
3. **Use Preview Words**: Set to 3-5 words for better context
4. **Regular Practice**: Consistency improves reading speed over time
5. **Minimize Subvocalization**: Avoid "hearing" words in your head
6. **Use Resume Feature**: Take breaks and resume exactly where you left off

## Troubleshooting

### RSVP Won't Start
- Ensure the document has extractable text
- Try manually starting RSVP from the menu first
- Check that tap-to-launch is enabled in settings

### Text Extraction Issues
- Some PDF files may have non-extractable text
- Try converting to EPUB format for better compatibility
- Ensure the document is not password-protected

### Performance Issues
- Reduce preview word count if the interface feels slow
- Lower the reading speed if words appear too quickly
- Restart KOReader if the plugin becomes unresponsive

## Technical Details

- **Supported Documents**: PDF, EPUB, MOBI, and other text-based formats
- **Memory Efficient**: Minimal resource usage during operation
- **Page Tracking**: Uses content hashing for reliable position tracking
- **UTF-8 Compatible**: Works with international characters and languages

## License

This plugin is distributed under the same license as KOReader.

## Contributing

Contributions are welcome! Please submit issues and pull requests through the appropriate channels.

---

**Enjoy your enhanced reading experience with FastReader!** 📚⚡
