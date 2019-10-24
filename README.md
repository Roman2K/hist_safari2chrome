# Import Safari history into Chrome

Simple script that imports entries from the Safari history database into that of
Chrome

![Screenshot][screenshot]

## Usage

Back up first.

```bash
$ bundle exec ruby import.rb safari.db chrome.db [--verbose --progress]
````

Can be run multiple times as the import process is indempotent. Indeed,
duplicates are removed at the end.

Locations of SQLite database files in macOS:

* Safari: `~/Library/Safari/History.db`
* Chrome: `~/Library/Application Support/Google/Chrome/Default/History`

[Detailed instructions](https://github.com/Roman2K/hist_safari2chrome/issues/3#issuecomment-545005400)

## Credits

Thanks to @dropmeaword. This script is inspired by his gist
[browser_history.md][base].

[screenshot]: https://github.com/Roman2K/hist_safari2chrome/raw/master/screenshot.png
[base]: https://gist.github.com/dropmeaword/9372cbeb29e8390521c2
