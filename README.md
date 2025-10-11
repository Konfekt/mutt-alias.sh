Build Mutt/NeoMutt aliases from recent Maildir messages for fast tab-completion of recipients.

For convenient tab-completion of recently used e-mail addresses inside mutt, this shell script populates the `$mutt_alias` file with all e-mail addresses found in a recent mail in the `INBOX` or `Sent` (or any other local [maildir](https://gitlab.com/muttmua/mutt/-/wikis/MuttFaq/Maildir)) folder.

Parses RFC 5322 address lists from the To: header, decodes RFC 2047 display names, generates normalized aliases, deduplicates by address, and annotates entries with message date.

Links:
- Maildir overview: https://gitlab.com/muttmua/mutt/-/wikis/MuttFaq/Maildir
- RFC 5322 (address syntax): https://www.rfc-editor.org/rfc/rfc5322
- RFC 2047 (encoded-words): https://www.rfc-editor.org/rfc/rfc2047
- NeoMutt alias_file: https://neomutt.org/guide/reference.html#alias_file

# Usage

```sh
mutt-alias.sh [-a alias file] [-d days] [-p] [-f] [-F] [-b] [-n] [-C] [-h] DIRECTORIES
```

Add mutt/NeoMutt aliases for e-mail addresses found in the To: header of messages stored under Maildir-style DIRECTORIES (e.g., Sent/cur).

Options:
- -a FILE       Alias file path.
                Default: value of alias_file from mutt/neomutt, else parsed from ~/.muttrc.
- -d DAYS       Max age in days, based on the message Date: header. 0 = unlimited (default).
                Files are also pre-filtered by mtime for efficiency.
- -p            Purge entries previously added by this tool.
                Matches lines with the trailing marker: `# mutt-alias: e-mail sent on ...`.
- -f            Filter out newly added addresses that look impersonal (heuristic).
- -F            Filter out all impersonal-looking addresses across the whole alias file.
- -b            Backup current alias file to FILE.prev.
                With -n, the current file is moved to FILE.prev; otherwise a copy is made.
- -n            Create a new alias file instead of modifying the current one.
- -C            Keep commas in display names (e.g., "Doe, John" stays as is).
                Without -C, commas in "Last, First" are dropped in the stored display name.
- -h            Show help and exit.

# Examples

```sh
# Populate from Sent for the last year, back up, purge previous entries, and filter new impersonal addresses
mutt-alias.sh -d 365 -bpf "$XDG_DATA_HOME"/mbsync/work/Sent/cur

# Clean an existing alias file aggressively by filtering all impersonal addresses
mutt-alias.sh -F -a "$HOME/.mutt/aliases"

# Start a new alias file from multiple Maildirs
mutt-alias.sh -n -b -a "$HOME/.mutt/aliases" "$XDG_DATA_HOME"/mbsync/personal/Sent/cur "$XDG_DATA_HOME"/mbsync/work/Sent/cur

# Keep commas in display names
mutt-alias.sh -C -d 90 "$XDG_DATA_HOME"/mbsync/work/Sent/cur
```

## How it works

- Header parsing.
  - Unfolds To: and Date: headers.
  - Splits the To: address list with a state machine that ignores commas inside quotes, angle brackets, or comments, following RFC 5322.

- Name decoding and folding.
  - Decodes RFC 2047 encoded-words via Python’s email.header.
  - Falls back to Perl Encode::MIME::Header when Python is unavailable.
  - ASCII-folds display names (iconv //TRANSLIT preferred; Python/Perl/NFKD fallback) to produce readable, filesystem-safe aliases.

- Alias generation.
  - If a display name is present, build the alias from it after folding and lowercasing.
  - If the display name matches "Last, First", reorder to "First Last" for alias generation only.
  - Replace spaces with hyphens, keep alphanumerics, collapse other characters to single hyphens, and trim.
  - If the result is empty, fall back to a sanitized local-part.
  - Stored display name drops the comma in "Last, First" unless -C is set.
  - Email addresses are lowercased.

- Duplicate handling.
  - Preloads existing aliases and deduplicates by address (case-insensitive).

- Dating and annotation.
  - Parses Date: to epoch to compute age and annotate entries as:
    `# mutt-alias: e-mail sent on YYYY-MM-DD@HH:MM:SS`.
  - If the Date: header cannot be parsed, the original Date: string is annotated.

- Filtering (impersonal address heuristics).
  - Heuristics match typical no-reply/daemon/unsubscribe patterns, very long numeric tokens, and similar.
  - -f applies the filter only to newly added entries in this run.
  - -F applies the filter to the whole alias file after merging new entries.

- Purging.
  - -p removes only entries previously added by this tool, detected by the trailing marker comment.

## Recommended inputs

- Prefer Sent/cur to populate recipients relevant for composition.
- Any Maildir directory works (INBOX/cur, Sent/cur, archives).

## Dependencies and compatibility

- Bash 3+ supported; Bash 4+ recommended for performance (associative arrays).
- Standard POSIX tools: find, awk, sed, grep, head, tail, pr.
- date:
  - GNU coreutils `date -d` / `date -ud` recommended for reliable Date: parsing.
  - On non-GNU systems, parsing may fail and fall back gracefully, still generating aliases.
- Decoding/folding:
  - iconv (with //TRANSLIT) recommended.
  - Python 3 for robust RFC 2047 decoding and Unicode folding fallback.
  - Perl with Encode::MIME::Header as an alternative.
- Mutt/NeoMutt optional:
  - Used to query alias_file if -a is omitted.
  - Otherwise, ~/.muttrc is parsed for a `set alias_file = ...` line.

## Notes on normalization

- Storage format: `alias <alias> "<Display Name>" <user@example.com> # mutt-alias: e-mail sent on ...`.
- Display names are escaped for double-quote safety.
- Email addresses and deduplication are case-insensitive.

## Setup

Best run periodically via (ana)cron, e.g., weekly, as described in:
https://konfekt.github.io/blog/2016/12/11/sane-cron-setup

## Related

- aliases-gen.sh:
  Parses addresses from a mail folder and adds them as aliases.
  Discussion of notmuch-based approaches: https://github.com/vimpostor/dotfiles/commit/449f7aaa61fc8caf796976567640868e247fcfce#commitcomment-132976373
- vim-mutt-aliases:
  Vim completion from the mutt alias file: https://github.com/Konfekt/vim-mutt-aliases
- auto_add_alias.sh:
  Add alias via `$display_filter` for each opened e-mail:
  http://wcaleb.org/blog/mutt-tips
  Extended in: https://github.com/teddywing/mutt-alias-auto-add

## License and credits

Based on Lee M. Yeoh’s mutt-vid (GPLv3): https://gitlab.com/protist/mutt-vid
This script is GPLv3 as well.

