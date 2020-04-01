# zim & ZIM.pm: ZIM Perl Toolkit
`zim` is small command-line tool written in Perl to deal with [ZIM files](https://openzim.org) as invented by Wikimedia CH and [Kiwix.org](https://kiwix.org), off-line version of Wikipedia, Wiktionary, Gutenberg and other datasets.

ZIM files are like ZIP or TAR.GZ files, but optimized to access individual files (.html, .jpg, .png) quickly.

**NOTE: The package is highly experimental and barely works, and API and notions are subject of changes.**

## Current State (zim 0.0.5 / ZIM.pm 0.0.8)
- listing metadata of ZIM file
- extract data from ZIM file
- search files in ZIM file by filename or full-text search (if fts index is included in ZIM file)
- basic web-server with fulltext search & RESTful full-text search & catalog
  - multiple ZIM files aka library support

## Todo
- ~~web-server: include search facility~~, included since 0.0.8
- ~~support ZIM libraries (multiple ZIM files):~~ included since 0.0.8 with `--library=<zim1>,<zim2>,...`
  - adding, removing ZIM files (e.g. adapting `kiwix-tools` XML format)
  - ~~multiple ZIM files but one web-server~~ included since 0.0.8
- clean up code (remove old code):
  - ~~make web-server use better socket handling~~ resolved since 0.0.7
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
USAGE zim 0.0.6: [<opts>] <zimfile> <cmd> [<arguments>]
   options:
      --verbose         increase verbosity
        -v or -vvv         "        "
      --version         print version and exit
      --index=<ix>      define which xapian index to consider, fts or title (default: fulltext)
      --regexp          treat args as regexp, in combination of 'article', 'extract' commands
        -e                       "                      "
      --case_insens     case-insensitivity, in combination of 'search', and -e with 'article' and 'extract'
        -i                       "         "
      --output=<fname>  define output filename in combination with 'extract'
      --library=<z1>,<z2>,...    define a library of multiple zim files for 'server' operation (experimental)
      --port=<p>        set port for server (default: 8080)
      --ip=<ip>         set address to bind server (default: 0.0.0.0)
      --conf=<c1>,<c2>,...       define a set of configuration files (JSON), default ./zim.conf is considered
                                 may contain all --key=value => \"key\": \"value\"

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
      zim test.zim i                display metatada of zim file
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

Some ZIM files contain `/X/fulltext/xapian` and `/X/title/xapian`, or alternatively (older) at `/Z//fulltextIndex/xapian` which are full-text indexes in Xapian format, 
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
% zim wikipedia_en_all_maxi-2019-10.zim server
== zim web-server 0.0.4 (ZIM 0.0.3), listening on 0.0.0.0:8080
```

and then open the browser of your choice `http://127.0.0.1:8080`

**Hint**: You may pre-extract the xapian indexes by querying it via the command-line first:
```
% zim wikipedia_en_all_maxi-2019-10.zim q test
(takes a while)
```
so the first query via the browser won't take too long.

### Library Support
Very early support for multiple ZIM files but one web-server / site is available using `--library=` option:
```
zim --library=wikipedia_en_all_maxi-2019-10.zim,wiktionary_en_all_maxi_2020-01.zim,gutenberg_en_all_2018-10.zim server
```
and provides you a simple way to switch between and search among all ZIM files in the "library".

You may create a `zim.conf` (JSON) like:
```
{ 
   "library": "wikipedia_en_all_mini.zim,wikiquote_en_all_maxi.zim,wiktionary_en_all_maxi_2020-01.zim,wikispecies_en_all_maxi_2020-01.zim"
}
```
and either launch `zim` in the same directory or reference the configuration file:
```
% ls zim.conf
zim.conf
% zim server
- or - 
% zim --conf=/some/where/zim.conf
```
**Note**: `--library` is only considered for `server` operation, other commands do not support library yet.

### RESTful API

The endpoint is `http://127.0.0.1:8080/rest` and takes `GET` request arguments:

#### RESTful: Full Text Search
- `q`: the query term
- `content`: define optionally the base in case multiple ZIM files are served with `--library`
- `offset`:  define offset of results, default: 0
- `limit`: limit results, default: 100
- `_pretty=` `0` or `1` to enable pretty JSON formatting

Example: `http://127.0.0.1/rest?q=test&_pretty=1`

returns something like this:
```
{
   "results" : {
      "hits" : [
         {
            "_id" : 1676,
            "id" : "3592",
            "mimetype" : "text/html",
            "namespace" : "A",
            "rank" : 1,
            "revision" : 0,
            "score" : 1,
            "title" : "Font configuration/Examples",
            "url" : "/A/Font_configuration/Examples"
         },
         {
            "_id" : 786,
            "id" : "3583",
            "mimetype" : "text/html",
            "namespace" : "A",
            "rank" : 2,
            "revision" : 0,
            "score" : 0.99,
            "title" : "Font Configuration/Chinese ()",
            "url" : "/A/Font_Configuration/Chinese_()"
         },
         ...
      ]
   },
   "server" : {
      "date" : "Mon Mar 30 08:21:16 2020",
      "elapsed" : 0.035167932510376,
      "name" : "zim web-server 0.0.4 (ZIM 0.0.3)",
      "time" : 1585549276.48143
   }
}
```

#### RESTful: Catalog

Addtionally `http://127.0.0.1:8080/rest?catalog&_pretty=1` provides the catalog or content of the library of ZIM files currently served, something like this:
```
{
   "results": { 
      "catalog" : [
         {
            "base" : "wikipedia_en_all_mini",
            "home" : "/wikipedia_en_all_mini/A/User:The_other_Kiwix_guy/Landing",
            "meta" : {
               "articleCount" : 14398965,
               "checksumPos" : 11329506544,
               "clusterCount" : 19889,
               "clusterPtrPos" : 967038701,
               "file" : "wikipedia_en_all_mini.zim",
               "filesize" : 11329506560,
               "layoutPage" : 4294967295,
               "magicNumber" : 90,
               "mainPage" : 13391338,
               "mimeListPos" : 80,
               "mtime" : 1584558562,
               "titlePtrPos" : 115191936,
               "urlPtrPos" : 216,
               "uuid" : "e5827ab7fe15b4911102d2f2c1a41ff7",
               "version" : 5
            },
            "title" : "Wikipedia"
         },
         {
            "base" : "wikiquote_en_all_maxi",
            "home" : "/wikiquote_en_all_maxi/A/Main_Page",
            "meta" : {
               "articleCount" : 102516,
               "checksumPos" : 704843569,
               "clusterCount" : 571,
               "clusterPtrPos" : 6153189,
               "file" : "wikiquote_en_all_maxi.zim",
               "filesize" : 704843585,
               "layoutPage" : 4294967295,
               "magicNumber" : 90,
               "mainPage" : 36464,
               "mimeListPos" : 80,
               "mtime" : 1581022402,
               "titlePtrPos" : 820350,
               "urlPtrPos" : 222,
               "uuid" : "eea238af8d02a7096a1098fd7d92a0c1",
               "version" : 5
            },
            "title" : "Wikiquote"
         },
   ....
}
```

## ZIM.pm

**Note: due the experimental nature the API might change until VERSION 0.1.0 is reached.**

```
use ZIM;
use JSON;   # -- just for to_json() below

my $z = new ZIM({ file => "test.zim" });

foreach my $u (@{$z->index()}) {
   print "$u\n";
}

print $z->article("/A/Test");

$z->article("/A/Test", { dest => "Test.html" });

my $r = $z->index("test", { case_insense => 1 });
foreach my $u (@$r) {
   print "$u\n";
}

my $rs = $z->fts("test", { index => 'title' });
foreach my $e (@$rs) {
   print to_json($e, { pretty => 1, canonical => 1 });
}

$z->server({ ip => '127.0.0.1', port => 8088 });
```

