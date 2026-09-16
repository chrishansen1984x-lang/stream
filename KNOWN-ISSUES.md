# Beta limitations

- Some streams require headers or external subtitles that the current playback paths do not fully support.
- Descriptive audio without identifying metadata can still be selected incorrectly. Choose the regular soundtrack from the audio menu.
- Seeking while paused was inconsistent in a silent MP4 test file using VLC. H.264/AAC and HLS test samples behaved correctly.
- Competing edits to addon lists or preferences on different devices are last-writer-wins. First connection to an existing sync endpoint adopts its configuration before a sync baseline exists.
- Automatic source selection and watched status sometimes need correcting. You can choose a source yourself or use Mark as watched.
- Testing so far has focused on Apple silicon Macs. The Intel build compiles, but playback has not been tested on an Intel Mac.

Do not include personal addon configurations or media URLs in public bug reports.
