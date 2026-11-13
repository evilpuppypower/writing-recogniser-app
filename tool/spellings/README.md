# Spelling table for regional English

`assets/spellings.tsv` holds each word's spelling in American, British and Canadian English, one word a line, separated by tabs, in that order. The app uses it to put handwriting readings into the English chosen in Settings.

It's built from VarCon (Variant Conversion Info), part of SCOWL, by Kevin Atkinson and Benjamin Titze. Its permissive licence is shown in the app's licences page.

- Source: https://raw.githubusercontent.com/en-wl/wordlist/master/varcon/varcon.txt
- SHA-256 of the file used: `75af63da46ec12d7eb14b9f1ba8d3898d484dd6872755b73c921b215875a3629`
- Built with: `PRIVACY_PATTERNS_FILE=… python3 -I tool/spellings/build.py varcon.txt assets/spellings.tsv` (words matching the owner's private patterns are left out, as everything in this public repo is checked against them).

The script follows VarCon's own rules for spellings it leaves out (no British "-ize" spelling means the "-ise" one; no Canadian means the "-ize" one). It leaves out phrases and any word with two meanings spelt differently (e.g. "program", "check", "meter"), so a word is only changed when that's always right.
