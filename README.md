# zim & ZIM.pm: ZIM Perl Toolkit
`zim` is small command-line tool written in Perl to deal with [ZIM files](https://openzim.org) as invented by Wikimedia CH and [Kiwix.org](https://kiwix.org), off-line version of Wikipedia, Wiktionary, Gutenberg and other datasets.

ZIM files are like ZIP or TAR.GZ files, but optimized to access individual files (.html, .jpg, .png) quickly.

**Please Note: The package is highly experimental and barely works, and API and notions are subject of changes.**

## Current State
- listing metadata of ZIM file
- extract data from ZIM file
- search files in ZIM file by filename or full text search (if fts index is included in ZIM file)
- basic web-server & RESTful full-text search
 
## Todo
- web-server: include search facility
- support ZIM libraries (multiple ZIM files):
  - adding, removing ZIM files (e.g. adapting `kiwix-tools` XML format)
  - multiple ZIM files but one web-server
- clean up code (remove old code):
  - make web-server use better socket handling (exiting web-server and restart make take 1min wait until socket is released)
  - `ZIM.pm` proper documentation for CPAN release

## Download
```
git clone https://github.com/Spiritdude/ZIM
cd ZIM
```

## Installation
```
sudo make requirements
make install
```

Note:
- the `ZIM.pm` will be installed only for current user `~/lib/perl5`
- the `zim` (CLI) is installed only for current user `~/bin/`

due the experimental nature of both.

## Usage
```
USAGE zim 0.0.4: [<opts>] <zimfile> <cmd> [<arguments>]
   options:
      --verbose         increase verbosity
        -v or -vvv         "        "
      --version         print version and exit
      --index=<ix>      define which xapian index to consider, fts or title (default: fts)
      --regexp          treat args as regexp, in combination of 'article', 'extract' commands
        -e                       "                      "
      --case_insens     case-insensitivity, in combination of 'search', and -e with 'article' and 'extract'
        -i                       "         "
      --port=<p>        set port for server (default: 8080)
      --ip=<ip>         set address to bind server (default: 0.0.0.0)

   commands:
      info              show info of zim file
         i                  "       "
      index             list all entries (default)
         ix                 "       "
         ls                 "       "
      search <q>        list all entries with matching query, use optionally -i
         s <q>              "                  "
      article [<u>..]   output article content, optionally use -e and -i
         a [<u>..]          "                  "
      extract [<u>..]   extract article content to file, optionally use -e and -i
         x [<u>..]          "                  "
      query <q>         query internal xapian indices (fts or title), use --index=title to switch
         q <q>              "                  "
      server            start web-server serving zim-file content
      
   examples:
      zim test.zim                  list all entries
      zim test.zim i                display info of zim file
      zim test.zim ix               display entire index of zim file
      zim test.zim -i s test        list urls of matching filenames
      zim test.zim a /A/Test        output article(s)
      zim test.zim -e -i a test     output articles matching terms case-insensitive
      zim test.zim x /A/Test        extract article content as file(s)
      zim test.zim -e x '\.png'     extract article content matching regexp
      zim test.zim q test           query fts using internal xapian index (if there are such)
      zim test.zim --index=title q test     query fts but only titles
      zim test.zim server           start web-server

```

## Full Text Search

Some ZIM files contain `/X/fts/xapian` and `/X/title/xapian` which are full text indexes in Xapian format, 
those are extracted once if you use `query` or `q` command first, and may take some time. 

Once they are extracted, querying those full text indexes is fast.

```
% zim archlinux_en_all_maxi_2020-02.zim --index=title q x11
{"_id":7730,"_url":"/A/X11","id":9836,"mimetype":"text/html","namespace":"A","rank":1,"revision":0,"score":1,"title":"","url":"Xorg"}
{"_id":4991,"_url":"/A/X11_forwarding","id":6807,"mimetype":"text/html","namespace":"A","rank":2,"revision":0,"score":0.93,"title":"","url":"OpenSSH"}
{"_id":7916,"_url":"/A/X11_(Português)","id":9850,"mimetype":"text/html","namespace":"A","rank":3,"revision":0,"score":0.93,"title":"Xorg (Português)","url":"Xorg_(Português)"}
```

By default the results are given as JSON.

## Web Server

The main intent of ZIM files are to provide an entire web-site for off-line operations, like having Wikipedia fully functional 
but running on a dedicated web-server.
```
% zim wikipedia_en_all_maxi-2019-08.zim server
== zim web-server 0.0.4 (ZIM 0.0.3), listening on 0.0.0.0:8080
```

and then open the browser of your choice `http://127.0.0.1:8080`

**Note:** if you exit the web-server (e.g. CTRL-C) restarting the web-server may fail for 1min as child processes may still hold on the socket; will be fixed in the future.

### RESTful API

The endpoint is `http://127.0.0.1:8080/rest` and takes `GET` request arguments:
- `q`: the query term
- `offset`:  define offset of results, default: 0
- `limit`: limit results, default: 100
- `_pretty=` `0` or `1` to enable pretty JSON formatting

Example: `http://127.0.0.1/rest?q=test&_pretty=1`

returns something like this:
```
{
   "hits" : [
      {
         "_id" : 1676,
         "_url" : "/A/Font_configuration/Examples",
         "id" : 3592,
         "mimetype" : "text/html",
         "namespace" : "A",
         "rank" : 1,
         "revision" : 0,
         "score" : 1,
         "title" : "Font configuration/Examples",
         "url" : "Font_configuration/Examples"
      },
      {
         "_id" : 786,
         "_url" : "/A/Font_Configuration/Chinese_()",
         "id" : 3583,
         "mimetype" : "text/html",
         "namespace" : "A",
         "rank" : 2,
         "revision" : 0,
         "score" : 0.99,
         "title" : "Font Configuration/Chinese ()",
         "url" : "Font_Configuration/Chinese_()"
      },
      ...
      {
         "_id" : 3242,
         "_url" : "/A/X2Go",
         "id" : 9663,
         "mimetype" : "text/html",
         "namespace" : "A",
         "rank" : 100,
         "revision" : 0,
         "score" : 0.86,
         "title" : "",
         "url" : "X2Go"
      }
   ],
   "server" : {
      "date" : "Mon Mar 30 08:21:16 2020",
      "elapsed" : 0.035167932510376,
      "name" : "zim web-server 0.0.4 (ZIM 0.0.3)",
      "time" : 1585549276.48143
   }
}
```

## ZIM.pm

**Note: due the experimental nature the API might change until VERSION 0.1.0 is reached.**

Some brief overview of `ZIM.pm`:
```
my $z = new ZIM({ file => "test.zim" });

foreach my $u ($z->index()) {
   print "$u\n";
}

print $z->article("/A/Test");

$z->article("/A/Test",{ dest => "Test.html" });

foreach my $u ($z->index("test", { case_insense => 1 })) {
   print "$u\n";
}

foreach my $u ($z->fts("test",{ index => 'title' })) {
   print "$u\n";
}
```

