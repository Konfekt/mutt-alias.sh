For convenient tab-completion of recently used e-mail addresses inside mutt, this shell script populates the `$mutt_alias` file with all e-mail addresses found in a recent mail in the `INBOX` or `Sent` (or any other local [maildir](https://gitlab.com/muttmua/mutt/-/wikis/MuttFaq/Maildir)) folder.

# Usage

```sh
mutt-alias.sh [-a alias file] [-d days] [-p] [-f] [-b] [-n] DIRECTORIES

Add mutt aliases for all e-mails addresses found in local maildir DIRECTORIES.

OPTIONS:
  -a          alias file (default: value of $alias_file in ~/.muttrc)
  -d          maximal number of days since last sent mail to (default: 0 = unlimited)
  -p          purge aliases previously added by mutt-alias.sh
  -f          filter out email addresses that are probably impersonal
  -b          backup the current alias file (if it exists) to *.prev
  -n          create a new alias file instead of modifying the current one
  -h          display this help and exit

```

For example, if you use `mbsync`, then `DIRECTORIES` could be

```sh
    $XDG_DATA_HOME/mbsync/Sent/cur
```
and this command would add all addresses you sent an e-mail to in the last year:
```sh
  mutt-alias.sh -d 365 -bpf "$XDG_DATA_HOME"/mbsync/work/Sent/cur
```

To decode [7-bit ASCII encoded full names that contain non-ASCII letters](https://tools.ietf.org/html/rfc2047) (which start, for example, with `=?UTF-8?Q?` or `=?ISO-8859-1?Q?`), ensure that `perl` is executable and the [Encode::MIME::Header](https://perldoc.perl.org/Encode/MIME/Header.html) module is installed.

# Related

The [aliases-gen.sh](https://github.com/vimpostor/dotfiles/blob/master/scripts/aliases-gen.sh) script by @vimpostor parses all addresses from a mail folder and adds them as aliases but [is based on the notmuch-indexer, which is much superior because it avoids doing low-level mail parsing in Bash](https://github.com/vimpostor/dotfiles/commit/449f7aaa61fc8caf796976567640868e247fcfce#commitcomment-132976373).

The [vim-mutt-aliases](https://github.com/Konfekt/vim-mutt-aliases) plug-in lets you complete e-mail addresses in Vim by those in your `mutt` alias file.

The [auto_add_alias.sh](http://wcaleb.org/blog/mutt-tips) shell script adds an alias via `$display_fiter` for every opened e-mail (and is expanded on in [mutt-alias-auto-add](https://github.com/teddywing/mutt-alias-auto-add)).

# Setup

Best run by a, say weekly, (ana)cronjob, on AC/DC as outlined in my [blogpost on a sane (ana)cron setup](https://konfekt.github.io/blog/2016/12/11/sane-cron-setup).

# Credits

Lee M. Yeoh's shell script [mutt-vid](https://gitlab.com/protist/mutt-vid) served as a template and which is under GNU General Public License v3.0;
thus, the same conditions apply.

