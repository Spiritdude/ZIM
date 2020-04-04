package ZIM;

# == ZIM.pm ==
#    based on zimHttpServer.pl written by Pedro González (2012/04/06)
#    turned into ZIM.pm by Rene K. Mueller (2020/03/28) with enhancements as listed below
#
# Description:
#   provides basic OO interface to ZIM files as provided by kiwix.org
#
# History:
# 2020/04/04: 0.0.10: in server() don't resolve redirects internally, but via browser (*.stackexchange.zim rely on it)
# 2020/04/03: 0.0.9: adding url2id cache, fixing file-not-found for server() library operation
# 2020/03/31: 0.0.8: preliminary 64bit cluster size support to support large fulltext indexes (>4GB), improved server() web-gui supporting library (multiple zim files)
# 2020/03/30: 0.0.7: support large article extraction direct to file (without large memory consumption) for wikipedia.zim xapian indices
# 2020/03/30: 0.0.6: preliminary support for library (multiple zim) for server()
# 2020/03/30: 0.0.5: renaming methods: article(url) and articleById(n)
# 2020/03/30: 0.0.4: further code clean up, REST: enable CORS by default, offset & limit considered
# 2020/03/29: 0.0.3: server() barely functional
# 2020/03/29: 0.0.2: fts() with kiwix full text xapian-based indexes (fts and title) support
# 2020/03/28: 0.0.1: initial version, just using zimHttpServer.pl and objectivy it step by step, added info() to return header plus some additional info

our $NAME = "ZIM";
our $VERSION = '0.0.10';

use strict;
use Search::Xapian;
use Time::HiRes 'time';
# use IO::Uncompress::AnyUncompress qw(anyuncompress $AnyUncompressError); 
use JSON;
use IO::Socket;
use IO::Select;

sub new {
   my($class) = shift;
   my $self = { };
   my $arg = shift;
   
   bless($self,$class);

   foreach my $k (keys %$arg) {
      $self->{$k} = $arg->{$k};
   }

   @{$self->{error}} = ();

   if($arg->{library}) { 
      # -- create internal catalog with metadata for webgui                   
      foreach my $f (@{$arg->{library}}) {
         my $b = $f; $b =~ s/\.zim$//;
         print "INF: library: adding $b ($f)\n" if($self->{verbose});
         $self->{catalog}->{$b} = new ZIM({file=>$f,verbose=>$self->{verbose}});
         my $me = $self->{catalog}->{$b};
         $me->entry($me->{header}->{mainPage});
         my($home,$title,$icon);
         $home = "/$b/".$me->{article}->{namespace}."/".$me->{article}->{url};
         $title = $me->article("/M/Title") || $me->article("/M/Creator") || $b;
         $title =~ s/([\w ]{12,24})\s[\W\S].*/$1/;   # -- truncate title sensible
         foreach my $i ('/-/favicon','/I/favicon.png') {
            $icon = "/$b$i", last if($me->article($i));
         }
         $me->error(1);    # -- clear error if favicon(s) are not found
         push(@{$self->{_catalog}},{ base=>$b, home=>$home, title=>$title, meta=>$me->{header}, icon => $icon });
      }
      return $self;
   }
   
   die "ZIM.pm: ERR: zim file must end with .zim, '$arg->{file}' does not\n" unless($arg->{file}=~/\.zim$/);
   open (my $fh, $arg->{file}) || die "ZIM.pm: ERR: file not found <$arg->{file}>\n";

   $self->{fh} = $fh;
   # -- read zim header
   read($fh, $_, 4); $self->{header}->{"magicNumber"} = unpack("c*"); # ZIM\x04
   read($fh, $_, 4); $self->{header}->{"version"} = unpack("I");
   read($fh, $_, 16); $self->{header}->{"uuid"} = unpack("H*");
   read($fh, $_, 4); $self->{header}->{"articleCount"} = unpack("I");
   read($fh, $_, 4); $self->{header}->{"clusterCount"} = unpack("I");
   read($fh, $_, 8); $self->{header}->{"urlPtrPos"} = unpack("Q");
   read($fh, $_, 8); $self->{header}->{"titlePtrPos"} = unpack("Q");
   read($fh, $_, 8); $self->{header}->{"clusterPtrPos"} = unpack("Q");
   read($fh, $_, 8); $self->{header}->{"mimeListPos"} = unpack("Q");
   read($fh, $_, 4); $self->{header}->{"mainPage"} = unpack("I");
   read($fh, $_, 4); $self->{header}->{"layoutPage"} = unpack("I");
   read($fh, $_, 8); $self->{header}->{"checksumPos"} = unpack("Q");
   
   $self->{header}->{file} = $arg->{file};
   
   @_ = stat($arg->{file});      # -- retrieve metadata of zim file itself
   $self->{header}->{filesize} = $_[7];
   $self->{header}->{mtime} = $_[9];
   
   # -- load MIME TYPE LIST
   my @mime;
   seek($fh, $self->{header}->{"mimeListPos"}, 0); 
   $/ = "\x00";
   for(my $a=0; 1; $a++){
   	my $b = <$fh>;
   	chop($b);
   	last if($b eq "");
   	$mime[$a] = $b;
   }
   $self->{mime} = \@mime;
   $/ = "\n";

   my $me = $self;
   my $b = $arg->{file}; $b =~ s/\.zim$//;
   $me->entry($me->{header}->{mainPage});
   my($home,$title,$icon);
   $home = "/".$me->{article}->{namespace}."/".$me->{article}->{url};
   $title = $me->article("/M/Title") || $me->article("/M/Creator") || $b;
   foreach my $i ('/-/favicon','/I/favicon.png') {
      $icon = "/$b$i", last if($me->article($i));
   }
   $self->error(1);     # -- clear error if favicon(s) are not found
   
   push(@{$self->{_catalog}},{ home=>$home, title=>$title, meta=>$me->{header}, icon => $icon });

   return $self;
}

sub info {
   my $self = shift;
   return $self->{header};
}

sub error {
   my $self = shift;
   my $clear = shift;
   my $s = join("\n",@{$self->{error}});
   $self->{error} = [] if($clear);
   return $s;
}

# -- read ARTICLE NUMBER (sort by url) into URL POINTER LIST
#    return ARTICLE NUMBER POINTER
sub url_pointer {
   my $self = shift;
   my $article = shift;
   my $fh = $self->{fh};
   #push(@{$self->{error}},"article number $article exceeds $self->{header}->{articleCount}"), return ''
   return -1 if $article >= $self->{header}->{"articleCount"};
   my $pos = $self->{header}->{"urlPtrPos"};
   $pos += $article*8;
   seek($fh, $pos, 0);
   read($fh, $_, 8); my $ret = unpack("Q");
   return $ret;
}

# -- read ARTICLE NUMBER (sort by title) into TITLE POINTER LIST
#    return ARTICLE NUMBER (not pointer)
sub title_pointer {
   my $self = shift;
   my $article_by_title = shift;
   my $fh = $self->{fh};
   return -1 if $article_by_title >= $self->{header}->{"articleCount"};
   my $pos = $self->{header}->{"titlePtrPos"};
   $pos += $article_by_title*4;
   seek($fh, $pos,0);
   read($fh, $_, 4); my $ret = unpack("I");
   return $ret;
}

# -- read ARTICLE NUMBER 
#    load ARTICLE ENTRY that is point by ARTICLE NUMBER POINTER
#       or load REDIRECT ENTRY
sub entry {
   # directory entries
   # article entry
   # redirect entry
   my $self = shift;
   my $article = shift;

   my $fh = $self->{fh};
   $self->{article} = undef;
   $self->{article}->{number} = $article;

   my $pos = $self->url_pointer($article);
   return $pos if($pos<0);
   seek($fh, $pos,0);
   read($fh, $_, 2); $self->{article}->{"mimetype"} = unpack("s");
   read($fh, $_, 1); $self->{article}->{"parameter_len"} = unpack("H*");
   read($fh, $_, 1); $self->{article}->{"namespace"} = unpack("a");
   read($fh, $_, 4); $self->{article}->{"revision"} = unpack("I");
   if($self->{article}->{"mimetype"} < 0){
      read($fh, $_, 4); $self->{article}->{"redirect_index"} = unpack("I");
   } else {
      read($fh, $_, 4); $self->{article}->{"cluster_number"} = unpack("I");
      read($fh, $_, 4); $self->{article}->{"blob_number"} = unpack("I");
   }
   $/ = "\x00";
   $self->{article}->{"url"} = <$fh>;
   $self->{article}->{"title"} = <$fh>;
   chop($self->{article}->{"url"});
   chop($self->{article}->{"title"});
   $/ = "\n";
   read($fh, $_, $self->{article}->{"parameter_len"}); $self->{article}->{"parameter"} = unpack("H*");
}

# -- read CLUSTER NUMBER into CLUSTER POINTER LIST 
#    return CLUSTER NUMBER POINTER
sub cluster_pointer {
   my $self = shift;
   my $cluster = shift;
   my $fh = $self->{fh};
   if($cluster >= $self->{header}->{"clusterCount"}) {
      return $self->{header}->{"checksumPos"} 
      #push(@{$self->{error}},"cluster_pointer: #$cluster exceeds maximum of $self->{header}->{clusterCount}");
      #die "ZIM.pm: cluster #$cluster exceeds maximum of $self->{header}->{clusterCount}\n";
      #return 0;
   }
   my $pos = $self->{header}->{"clusterPtrPos"};
   $pos += $cluster*8;
   seek($fh, $pos,0);
   read($fh, $_, 8); my $ret = unpack("Q");
   return $ret;
}

# -- read CLUSTER NUMBER
#    decompress CLUSTER
#    read BLOB NUMBER 
sub cluster_blob {
   my $self = shift;
   my $cluster = shift;
   my $blob = shift;
   my $opts = shift;
   my $fh = $self->{fh};
   my $ret;

   print "INF: #$$: cluster blob (cluster=$cluster)\n" if($self->{verbose}>2);

   my $pos = $self->cluster_pointer($cluster);
   my $size = $self->cluster_pointer($cluster+1) - $pos - 1;
   
   print "INF: #$$: cluster blob (cluster=$cluster, pos=$pos, size=$size)\n" if($self->{verbose}>2);
   
   seek($fh, $pos, 0);

   my %cluster;

   read($fh, $_, 1); $cluster{compression_type} = unpack("C");
   
   $cluster{offset_size} = $cluster{compression_type} & (1<<4) ? 8 : 4;    # -- see https://openzim.org/wiki/ZIM_file_format

   # print "$cluster{compression_type}:$cluster{offset_size}\n";
   
   # -- compressed?
   if(($cluster{compression_type} & 0x0f) == 4) {
      my $data;
      
      # -- FIXIT: do not read large compressed files into memory, but small chunks only to files
      read($fh, $data, $size);

      # -- FIXIT: use XZ library without creating tmp file (seems ::Uncompress work only via files, not data direct)
      if(1) {     # -- old code
         # -- extract data separately into a file, uncompress, and extract part of it
         my $tmp = "/tmp/zim_tmpfile_cluster$cluster-pid$$";
         open(DATA, ">$tmp.xz");
         print DATA $data;
         close(DATA);
         
         #`xz -d -f $tmp.xz`;
         # -- decompress it
         if(fork()==0) {
            exec('xz','-d','-f',"$tmp.xz");
         }
         wait;

         open(DATA, $tmp);
         seek(DATA, $blob*4, 0);
         read(DATA, $_, 4); my $posStart = unpack("I");
         read(DATA, $_, 4); my $posEnd = unpack("I");
         seek(DATA, $posStart, 0);

         read(DATA, $ret, $posEnd-$posStart);         # -- read into memory
         close(DATA);
         
         unlink $tmp;
         
      } else {    # -- new code
         if(0) {
            my $s = anyuncompress $data => $ret;         # -- throws error (not usable): can't handle data, only files
            my $off = $blob*4;
            $_ = substr($ret,$off,4); my $posStart = unpack("I"); $off += 4;
            $_ = substr($ret,$off,4); my $posEnd = unpack("I"); $off += 4;
            $ret = substr($ret,$posStart,$posEnd-$posStart);

         } else {       # -- still cumbersome, and additionally won't work (yet)
            my $file = "/tmp/zim_tmpfile_cluster$cluster-pid$$";
            open(my $fhz,">","$file.xz");
            print $fhz $data;
            close($fhz);
            my $z = new IO::Uncompress::AnyUncompress("$file.xz");         # -- must be a file, can't handle data itself
            if($z) {
               seek($z, $blob*4, 0);
               read($z, $_, 4); my $posStart = unpack("I");
               read($z, $_, 4); my $posEnd = unpack("I");
               seek($z, $posStart, 0);
               read($z, $ret, $posEnd-$posStart);
               close($z);
            } else {
               # -- uncomment next 2 lines as soon IO::Uncompress::AnyUncompress really works
               #print STDERR "ZIM.pm: ERR: #$$: XZ uncompress failed: $AnyUncompressError\n";
               #push(@{$self->{error}},"XZ uncompress failed: $AnyUncompressError");
               $ret = '';
            }
            unlink $file;
         }
      }
      if($opts && $opts->{dest}) {
         print "INF: #$$: writing $opts->{dest}\n" if($self->{verbose});
         open(my $fhx,">",$opts->{dest});
         print $fhx $ret;
         close $fhx;
      } else {
         return $ret;
      }

   } else {
      my $data;

      if(1 && ($size > 200_000_000 || ($opts && $opts->{dest}))) {
         if($opts && $opts->{dest}) {
            print "INF: #$$: writing $opts->{dest}\n" if($self->{verbose});
            my $off = tell $fh;
            seek($fh, $off+$blob*4, 0);
            read($fh, $_, $cluster{offset_size}); my $posStart = unpack($cluster{offset_size}==4?"I":"Q");
            read($fh, $_, $cluster{offset_size}); my $posEnd = unpack($cluster{offset_size}==4?"I":"Q");
            seek($fh, $off+$posStart, 0);

            $size = $posEnd-$posStart;
            print "INF: #$$: extract chunk size=$size (offset=$off, start=$posStart, end=$posEnd)\n" if($self->{verbose}>2);
            open(OUT,">",$opts->{dest});
            my $bs = 4096*1024;                          # -- use 4MB chunks
            while(1) {
               my $n = read($fh,$ret,$size >= $bs ? $bs : $size);
               $size -= $n;
               print OUT $ret;
               last if($size <= 0 || $n <= 0);
            }
            close OUT;
            return;
         } else {
            print STDERR "ZIM.pm: ERR: file too large (".fnum3($size)." bytes) to read into memory, rather extract to a file\n";
            exit 0;
         }
      } else {
         read($fh, $data, $size);
      }
      $_ = substr $data, $blob*4, 4; my $posStart = unpack("I");
      $_ = substr $data, $blob*4+4, 4; my $posEnd = unpack("I");
      $ret = substr $data, $posStart, $posEnd-$posStart;
      if($opts && $opts->{dest}) {
         print "INF: #$$: writing $opts->{dest}\n" if($self->{verbose});
         open(my $fhx,">",$opts->{dest});
         print $fhx $ret;
         close $fhx;
      }
      return $ret;
   }
}

# -- read ARTICLE NUMBER
#    return DATA
sub articleById {
   my $self = shift;
   my $an = shift;
   my $opts = shift;

   print "INF: #$$: articleById: #$an\n" if($self->{verbose}>1);

   while(1) {     # -- resolve redirects 
      my $p = $self->entry($an);
      #print to_json($self->{article},{pretty=>1,canonical=>1});
      push(@{$self->{error}},"article not found #$an"), return '' if($p<0);
      if(defined $self->{article}->{"redirect_index"} && !($opts && $opts->{no_redirect})) {
         $an = $self->{article}->{"redirect_index"};
      } else {
         return $opts && $opts->{metadata} ? 
            $self->{article} : 
            $opts && $opts->{no_redirect} && $self->{article}->{redirect_index} ? 
               $self->{article} :
               $self->cluster_blob($self->{article}->{"cluster_number"}, $self->{article}->{"blob_number"}, $opts);
         last;
      }
   }
}

# -- search url 
#    return DATA
sub article {
   my $self = shift;
   my $url = shift;
   my $opts = shift;
   my $max = $self->{header}->{"articleCount"};
   my $min = 0;
   my $an;

   if(!$url) {    # -- no url provided, then display mainPage
      return $self->articleById($self->{header}->{mainPage},$opts);
   }
   if(defined $self->{_url2id_cache}->{$url}) {
      $an = $self->{_url2id_cache}->{$url};
   } else {
      while(1) {     # -- simple binary search
         $an = int(($max+$min)/2);
         my $p = $self->entry($an,$opts);
         push(@{$self->{error}},"article <$url> not found"), return '' if($p<0);
         if("/$self->{article}->{namespace}/$self->{article}->{url}" gt "$url") {
            $max = $an-1;
         } elsif("/$self->{article}->{namespace}/$self->{article}->{url}" lt "$url") {
            $min = $an+1;
         } else {
            last;
         }
         # -- binary search (above) failed: we need to create an index, and fetch the title to compare
      	if(0 && $max < $min){
            $self->{article} = undef;
            $self->{article}->{url} = "pattern=$url";
            $self->{article}->{namespace} = "SEARCH";
            return "", unless $url =~ /^\/A/;
            # ($url) = grep {length($_)>1} split(/[\/\.\s]/, $url);
            $url =~ s#/A/##;
            my $m;
            foreach my $f ($self->index($url)) {
               print "INF: #$$: > $_" if($self->{verbose});
               $m .= "<a href=\"$_\">$_</a><br/>\n";
            }
            $self->{article}->{mimetype} = 0; # need for Content-Type: text/html; charset=utf-8
            return $m;
         }
         if($max < $min) {
            push(@{$self->{error}},"'$url' not found");
            return '';
         }
      }
      $self->{_url2id_cache}->{$url} = $an;   
   }
   return $self->articleById($an,$opts);
}

sub make_index {
   my $self = shift;

   # -- create index
   my $file = $self->{file};
   $file =~ s/zim$/index/;
   unless(-e $file) {
      $| = 1;
      print "INF: #$$: writing $file (index)\n" if($self->{verbose});
      open(INDEX, ">$file");
      for(my $n = 0; $n<$self->{header}->{"articleCount"}; $n++) {
         $self->entry($n);
         my $url = "/$self->{article}->{namespace}/$self->{article}->{url}";
         print INDEX "$url\n";
         print "\r$n" if($self->{verbose} && ($n%100) == 0);
         $self->{_url2id_cache}->{$url} = $n;
      }
   	print "\n" if($self->{verbose});
   	$| = 0;
   	close(INDEX);
   }
}

sub index {
   my $self = shift;
   my $url = shift;
   my $file = $self->{file};

   $file =~ s/zim$/index/;

   my @r; 
   
   $self->make_index();
   
   # -- list or search index
   print "INF: #$$: searching '$url' in $file\n" if($self->{verbose});

   my $n = 0;
   open(INDEX, "$file");
   while(<INDEX>){
      chop;
      print "INF: #$$: > $_\n" if($self->{verbose});
      if(defined $url) {
         push(@r,$_) if($self->{case_insens} && /$url/i || /$url/);
      } else {
         push(@r,$_);
         $self->{_url2id_cache}->{$_} = $n++;
      }
   }
   close(INDEX);
   return \@r;
}

sub fts {
   my $self = shift;
   my $q = shift;
   my $opts = shift;
   my $file;
   
   $file->{fulltext} = $self->{file}; $file->{fulltext} =~ s/zim$/fulltext.xapian/;
   $file->{title} = $self->{file}; $file->{title} =~ s/zim$/title.xapian/;

   if(!-e $file->{fulltext}) {
      print "INF: #$$: extract /X/fulltext/xapian -> $file->{fulltext}\n";
      $self->article("/X/fulltext/xapian",{dest=>$file->{fulltext}});
      $self->error(1);    # -- in case extraction failed
      if(!-e $file->{fulltext}) {          # -- failed? let's try another url (older)
         print "INF: #$$: extract /Z//fulltextIndex/xapian -> $file->{fulltext}\n";
         $self->article("/Z//fulltextIndex/xapian",{dest=>$file->{fulltext}});
         $self->error(1);    # -- in case extraction failed
      }
   }
   if(!-e $file->{title}) {
      print "INF: #$$: extract /X/title/xapian -> $file->{title}\n";
      $self->article("/X/title/xapian",{dest=>$file->{title}});
      $self->error(1);    # -- in case extraction failed
   }
   my $file_xapian = $file->{$opts->{index}||'fulltext'};
   print "INF: #$$: xapian index $file_xapian\n" if($self->{verbose}>1);
   if(1) {
      if(!-e $file_xapian) {
         print STDERR "WARN: #$$: no xapian index available for $self->{header}->{file}\n" unless($self->{quiet});
         return [];
      }
      my $db = Search::Xapian::Database->new($file_xapian); 
      
      # -- it seems we have to truncate the query for some indices (??!!)
      # $q = substr($q,0,7);    # -- 'microscope' -> 'microsc'

      my $enq = $db->enquire($q);
      print "INF: #$$: xapian query: ".$enq->get_query()->get_description()."\n" if($self->{verbose}>1);
      $opts = $opts || { };
      my @r = $enq->matches($opts->{offset}||0,$opts->{limit}||100);
      my @re;
      foreach my $m (@r) {
         my $doc = $m->get_document();
         my $e = { _id => $m->get_docid(), rank => $m->get_rank()+1, score => $m->get_percent()/100, url => "/".$doc->get_data() };
         $self->article($e->{url},{metadata=>1});
         #foreach my $k (keys %{$self->{article}}) {
         foreach my $k (qw(title revision number namespace mimetype)) {
            $e->{$k} = $self->{article}->{$k};
         }
         $e->{id} = $e->{number}; delete $e->{number};
         $e->{mimetype} = $e->{mimetype} >= 0 ? $self->{mime}->[$e->{mimetype}] : "";
         #print to_json($e,{pretty=>1,canonical=>1});
         push(@re,$e);
      }
      return \@re;
   }
   #if(!-e $file_tt && $self->article("/X/title/xapian",{dest=>$file_title})) {
   #} 
}

sub server {
   my $self = shift;
   my $fh = $self->{fh};

   $self->{port} = $self->{port} || 8080;
   $self->{ip} = $self->{ip} || '0.0.0.0';

   if(0) {     # -- old code
      my ($server_ip, $server_port) = ($self->{ip}, $self->{port});
      my ($PF_UNIX, $PF_INET, $PF_IMPLINK, $PF_NS) = (1..4) ;
      my ($SOCK_STREAM, $SOCK_DGRAM, $SOCK_RAW, $SOCK_SEQPACKET, $SOCK_RDM) = (1..5) ;
      my ($d1, $d2, $prototype) = getprotobyname ("tcp");
   
      socket(SSOCKET, $PF_INET, $SOCK_STREAM, $prototype) || die "ZIM.pm: ERR: socket: $!";
      bind(SSOCKET, pack("SnCCCCx8", 2, $server_port, split(/\./,$server_ip))) || die "ZIM.pm: ERR: bind: $!";
      listen(SSOCKET, 5) || die "ZIM.pm: ERR: connect: $!";
      
      $SIG{CHLD} = 'IGNORE';
      $SIG{PIPE} = 'IGNORE';
      
      while(1) {
      	my $client_addr = accept(CSOCKET,SSOCKET) || die "ZIM.pm: ERR: $!";
      	last unless fork;            # -- parent remains in while(), child exits
      }
      $self->processRequest(\*CSOCKET);

   } else {    # -- new code
      my $server = IO::Socket::INET->new(
         LocalAddr => $self->{ip},
         LocalPort => $self->{port},
         Type => SOCK_STREAM,
         Reuse => 1,
         # Blocking => 0,
         # Timeout => 0.5,
         Listen => 10 )
      or die "ZIM.pm: ERROR: can't start a tcp server on $self->{ip}:$self->{port}: $!\n";

      $SIG{PIPE} = 'IGNORE';
      $SIG{CHLD} = 'IGNORE';

      my $rs = new IO::Select();

      $rs->add($server);

      while(1) {
         my($rhs) = IO::Select->select($rs,undef,undef,0.1);
         foreach my $rh (@$rhs) {
            if($rh==$server) {
               my $c = $rh->accept();
               $rs->add($c);
               
            } else {
               if(fork()==0) {
                  $self->processRequest($rh);
                  exit;
               }
               close($rh);
               $rs->remove($rh);
            }
         }
      }
   }
}

sub processRequest {
   my $self = shift;
   my $cs = shift;
   
   my $fh;

   # -- we need to reopen zim file as we forked process
   if($self->{catalog}) {
      foreach my $e (sort keys %{$self->{catalog}}) {
         open(my $fh,"<",$self->{catalog}->{$e}->{file});
         $self->{catalog}->{$e}->{fh} = $fh;
      }
   } else {
      open($fh,"<",$self->{file});
      $self->{fh} = $fh;
   }
   
   # $cs->autoflush(1);
   
   while(1) {                # -- keep-alive operation (exit only if we fail to send)
      my $http_header;

      timeout(1,sub {
         while(1) {             # -- read the http request header
            if(0) {
               my $m;
               recv($cs, $m, 1000, 0);
               $http_header .= $m;
               last if(length($m)<1000);
            } else {            # -- read line-wise, performs better than recv()
               $_ = <$cs>;
               $http_header .= $_;
               last if(/^\s*$/);
            }
         }
      });
      exit if($@);      # -- timeout, exit (child) process
      
      # -- processing request
      if($http_header =~  /^GET (.+) HTTP\/1\./){
         # -- Request-Line Request HTTP-message
         #    ("OPTIONS", "GET", "HEAD", "POST", "PUT", "DELETE", "TRACE", "CONNECT", "$token+");
         my $url = $1;

         print "INF: #$$: server: requested $url\n" if($self->{verbose});

         my(@header,$status,$body,$mime);

         $status = 200;
         
         if($url =~ /^\/rest\?(.*)/) {
            my $in;
            my $st = time();
            foreach my $kv (split(/&/,$1)) {
               if($kv=~/(\w+)=(.*)/) {
                  my($k,$v) = ($1,$2);
                  $k =~ s/%(..)/chr(hex($1))/eg;
                  $v =~ s/%(..)/chr(hex($1))/eg;
                  $in->{$k} = $v;
               } elsif($kv=~/(\w+)/) {
                  $in->{$1}++;
               }
            }
            my $res = { };
            if($in->{q}) {
               my @r;
               if($self->{catalog}) {
                  if($in->{content}) {
                     @r = map { $_->{base} = $in->{content}; $_->{url} = "/$in->{content}$_->{url}"; $_ } @{$self->{catalog}->{$in->{content}}->fts($in->{q},$in)};
                  } else {
                     foreach my $e (sort keys %{$self->{catalog}}) {
                        my $me = $self->{catalog}->{$e};
                        push(@r,map { $_->{base} = $e; $_->{url} = "/$e$_->{url}"; $_ } @{$me->fts($in->{q})});  # -- rebase
                     }
                     @r = sort { $b->{score} <=> $a->{score} } @r;      # -- sort according score (merge all results)
                     my $r = 0;
                     @r = map { $_->{rank} = $r++; $_ } @r;             # -- rerank
                     @r = splice(@r,$in->{offset},$in->{limit}) if($in->{offset}||$in->{limit});      # -- apply limit & offset
                  }
               } else {
                  @r = @{$self->fts($in->{q},$in)};
               }
               if($in->{snippets}) {                           # -- let's try to extract relevant snippets
                  for(my $i=0; $i<$in->{snippets}; $i++) {
                     last if($i>=@r);
                     my $me = $self;
                     my $u;
                     if($self->{catalog} && $r[$i]->{base}) {
                        $me = $self->{catalog}->{$r[$i]->{base}};
                        $u = $r[$i]->{url};
                        $u =~ s/\/[^\/]+//;
                     } else {
                        $u = $r[$i]->{url};
                     }
                     my $body = $me->article($u);
                     my $headers = [];
                     foreach(split(/\n/,$body)) {
                        push(@{$headers->[$1-1]},$2) if(/<h(\d)[^>]*>([^<]+)<\/h/i);
                     }
                     # push(@{$headers->[0]},$r[$i]->{title}) unless($headers->[0]);
                     $body =~ s/<script>[^<]+<\/script>//mg;
                     $body =~ s/<\/?(p|br)>/ /ig;
                     $body =~ s/<[^>]+>//g;
                     $body =~ s/\s+/ /g;
                     my $exp = '';
                     my $q = $in->{q};
                     for(my $n=0; $n<5;) {
                        if($body =~ s/(.{5,40})($q)(.{5,40})//i) {
                           $exp .= "..$1<b>$2</b>$3..";
                           $n++;
                        } else {
                           last;
                        }
                     }
                     $r[$i]->{snippet} = $exp;
                     $r[$i]->{headers} = $headers;
                  }
               }
               $res = { hits => \@r };

            } elsif($in->{catalog}) {
               $res = { catalog => $self->{_catalog} ? $self->{_catalog} : [] };
            }
            $body = to_json({ 
               results => $res,
               server => {
                  name => "zim web-server $::VERSION ($NAME $VERSION)",
                  elapsed => time()-$st,
                  time => time(),
                  date => scalar localtime()
               }
            }, { pretty => $in->{_pretty}, canonical => 1});
            $mime = 'application/json';
            
         } else {
            my $me = $self;                              # -- me might point later to catalog entry itself
            my $base;
            
            $url =~ s/%(..)/chr(hex($1))/eg;

            if($self->{catalog}) {                       # -- dealing with a catalog, determine which entry
               if($url =~ s/\/([\w\.\-]+)\//\//) {
                  $base = $1;
                  if($self->{catalog}->{$base}) {
                     $me = $self->{catalog}->{$base};
                  } else {
                     push(@{$self->{error}},"unknown catalog entry '$base'");
                     $body = "unknown catalog entry";
                  }
               } else {                                  # -- provide overview of items in catalog
                  $body = "<html><head><title>".($self->{title}?$self->{title}:"ZIM Catalog")."</title><link href=\"data:image/x-png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAABHNCSVQICAgIfAhkiAAAAAlwSFlzAAABUAAAAVAB++UihAAAABl0RVh0U29mdHdhcmUAd3d3Lmlua3NjYXBlLm9yZ5vuPBoAAAHFSURBVFiF7Vavq8JgFL3bHuiwLehXLKJgXrGKImIy+gdYDWKyDNvCkn+DGMRgWrFrEsFkXNYJCgoWmeclRd/ew/1yM7wDt9zv3nvO7rZ7P46IQBGCj5L88wRIkkS6rtPhcKDRaESiKIYiAjfTNA2P6HQ6eDx/hz11IJlMPilLpVJveF477moKhQJOpxMAYLfbIZfLvb0D9NPBGEO1WoUkSWGQg7upiAqf9RtGgS8/yY1Gg0qlkuN4RVHINE2b3/MH1O/34QbZbNZWw1cHxuMxrdfrP88TiQSpqkrxeJwMw6Dtdvtr3HsmHM9jMpkAAPb7PfL5vLM5EJT1ej0AgGVZqNVqzgdREFapVGBZFgBAUZRX8cGSM8ZgmiYAYDqdguf58ARwHAdd1wEAm80GjDEnecEJaLVa9/deLped5gVDnslk7ptU0zQ3uf7JBUHAbDYDAKxWK8RisXAFtNttAMDlcoEsy27z/ZGn02kcj0cAgKqqXmr4E3CbdoZhQBTFcAUUi8X7oqnX655q+LoRLZdLkmWZzuczDYfDl/GDwYDm87nN70m5IAiuVjEANJtNWx3P6/h6vVK323WVs1gsbL7/S2nkAr4BqNINAhXMUgwAAAAASUVORK5CYII=\" rel=\"shortcut icon\" type=\"image/x-png\">
</head><style>html{font-family:Helvetica,Sans;margin:0;padding:0}body{background:#eee;margin:1.5em 3em}.icon{float:right;vertical-align:middle;height:2em}a,a:visited{color:#444;text-decoration:none}.entry{text-align:left;font-size:1.4em;width:20%;display:inline-block;margin:0.5em 1em;border:1px solid #ccc;border-radius:0.3em;padding:0.3em 0.6em;background:#fff;box-shadow:0 0 0.5em 0.1em #888;overflow:hidden;white-space:nowrap}.entry:hover{box-shadow: 0 0 0.5em 0.1em #55c;background:#eef}.catalog{text-align:center}.meta{margin:0.3em 0;font-size:0.5em;opacity:0.8}.id{font-size:0.8em;opacity:0.5;margin:0.3em 0}.footer{text-align:center;margin-top:3em;font-size:0.8em;opacity:0.7}</style><body><div class=catalog>";
                  foreach my $e (@{$self->{_catalog}}) {
                     my $meta = fnum3($e->{meta}->{articleCount}) . " articles".
                        "<div class=id>$e->{base} (".fnum3(int($e->{meta}->{filesize}/1024/1024))." MiB)</div>";
                     $body .= "<a href=\"$e->{home}\"><span class=entry><img class=icon src=\"$e->{icon}\"> $e->{title}<div class=meta>$meta</div></span></a>";
                  }
                  $body .= "</div><div class=footer><a href=\"https://github.com/Spiritdude/ZIM\">zim web-server</a> $::VERSION ($NAME $VERSION)</div></body></html>";
                  $mime = 'text/html';
               }
            }

            # -- after this point $me points to current zim file

            # -- homepage requested?
            if((!$body) && $url eq "/") {
               $me->entry($me->{header}->{mainPage});
               $url = "/".$me->{article}->{namespace}."/".$me->{article}->{url};
               push(@header,"Location: $url");        # -- let's redirect browser, so images and script all work properly
               $status = 307;
               $body = 'redirect';
            }

            $url = "/-/favicon" if $url eq "/favicon.ico";
            # $url =~ s#(/.*?/.*?)$#$1#;

            # $url = "/A$url" unless $body || $url =~ "/.*/";       # -- complete url if necessary (disabled)

            print "INF: #$$: server:   serving ".($base?"$base:":"")."$url\n" if($self->{verbose});
         
            $body = $body || $me->article($url,{no_redirect=>1});

            if(ref($body) eq 'HASH') {       # -- redirect? let's do it in the browser so call content is properly referenced
               $status = 307;
               $me->articleById($body->{redirect_index},{no_redirect=>1});    # -- retrieve new entry, so we know the new url
               $body = $me->{article};
               push(@header,"Location: ".($base ? "/$base" : "") . "/$body->{namespace}/$body->{url}");
               $body = 'redirect';
            }
               
            $mime = $mime || ($me->{article}->{mimetype} >= 0 ? $me->{mime}->[$me->{article}->{mimetype}] : "text/plain");

            if(1 && $mime eq 'text/html') {    # -- we need to change/tamper the HTML ...
               my $mh = "";
               # $mh .= "<base href=\"/$base/\">";
               $mh .= "<style>body{margin-top:3em !important}.zim_header{z-index:1000;position:fixed;width:100%;padding:0.3em 1em;text-align:center;background:#bbb;box-shadow:0 0 0.5em 0.1em #888;top:0;left:0;text-decoration:none}.zim_header.small{font-size:0.8em;}.zim_entry{background:#eee;margin:0 0.3em;padding:0.3em 0.6em;border:1px solid #ccc;border-radius:0.3em;text-decoration:none;color:#226}.zim_entry:hover{background:#eee}.zim_entry.selected{background:#eef}.zim_search{margin:0 0.5em;padding:0.2em 0.3em;background:#ffc;border:1px solid #aa8;border-radius:0.3em;}.zim_search_input,.zim_search_input:focus{padding:0.1em 0.3em;background:none;border:none;outline:none}.zim_results{z-index:200;display:none;margin:1em 4em;padding:1em 2em;background:#fff;border:1px solid #888;box-shadow: 0 0 0.5em 0.1em #888}.zim_results.active{display:block}#_zim_results_hint{font-size:0.8em;opacity:0.7}.hit{margin-bottom:1.5em}.hit .title{font-size:1.1em;color:#00c;margin:0.25em 0;display:block;}.snippet{font-size:0.8em;opacity:0.6}.snippet .heads{font-weight:bold;font-size:0.9em;margin-top:0.5em;}.hit_icon{vertical-align:middle;height:1.5em;margin-right: 0.5em;}\@keyframes blink{0%{opacity:0}50%{opacity:1}100%{opacity:0}} .blink{animation:blink 1s infinite ease-in-out}</style>";
               $mh .= "<script>
var _zim_base = \"$base\";
function _zim_search() {
   var q = document.getElementById('_zim_search_q').value;
   q = q.replace(/^\\s+/,'');
   q = q.replace(/\\s+\$/,'');
   if(q.length==0)
      return;
   var xhr = new XMLHttpRequest();

   var _id = document.getElementById('_zim_results_hint');
   _id.innerHTML = 'searching ...';
   _id.classList.toggle('blink',true);

   var id = document.getElementById('_zim_results');
   id.classList.toggle('active',false);
   id.innerHTML = '...';
   xhr.onload = function() {
      if(xhr.status >= 200 && xhr.status < 300) {
         //console.log(xhr.responseText);
         var data = JSON.parse(xhr.responseText);
         //console.log(data);
         if(data.results.hits.length>0)
            id.classList.toggle('active',true);
         else
            id.classList.toggle('active',false);
         var o = '';
         //id.innerHTML = JSON.stringify(data);
         if(data && data.results && data.results.hits) {
            var _id = document.getElementById('_zim_results_hint');
            _id.innerHTML = data.results.hits.length + ' results';
            _id.classList.toggle('blink',false);
            for(var e of data.results.hits) {
               if(e.title.length==0) {
                  e.title = e.url.replace(/.*\\//,'');
               }
               var sn = e.snippet || ''; 
               var hd = '';
               for(var h in e.headers) {
                  for(var t in e.headers[h]) {
                     if(hd.length>0)
                        hd += ' &middot; ';
                     if(e.headers[h][t])
                        hd += '<span class=snippet_header_'+h+'>' + e.headers[h][t] + '</span>';
                     if(t>10)
                        break;
                  }
               }
               if(hd.length>0) 
                  sn = sn + '<div class=heads>' + hd + '</div>';
               var ico = e.base ? '<img class=hit_icon src=\"/' + e.base + '/-/favicon\">' : '';
               o += '<div class=hit><a class=title href=\"' + e.url + '\">' + ico + e.title + '</a>' + (sn ? '<div class=snippet>'+sn+'</div>' : '') + '</div>';
            }
            id.innerHTML = o;
         } else {
            var _id = document.getElementById('_zim_results_hint');
            _id.classList.toggle('blink',false);
            _id.innerHTML = 'search failed';
         }
      }
   };
   var p = { q: q, snippets: 50, limit: 100 };
   xhr.open('GET','/rest?'+Object.keys(p).map(function(k){return k+'='+encodeURIComponent(p[k])}).join('&'));
   xhr.send();
}               
</script>";
               my $xtr = ''; #$base && @{$self->{_catalog}} > 6 ? "small" : "";
               $mh .= "<div class=\"zim_header $xtr\">";
               $mh .= "<a href=\"/\"><span class=zim_entry>&#127968;</span></a>"; # if($base);
               if($base) {
                  if($self->{catalog}) {
                     if(@{$self->{_catalog}}<=6) {
                        foreach my $e (@{$self->{_catalog}}) {
                           my $s = $e->{base} eq $base ? "selected" : "";
                           $mh .= "<a href=\"$e->{home}\"><span class=\"zim_entry $s\">$e->{title}</span></a>";
                        }
                     } else {
                        $mh .= "<select id=_zim_select name=zim_select onchange=\"document.location=document.getElementById('_zim_select').value\">";
                        foreach my $e (@{$self->{_catalog}}) {
                           my $s = $e->{base} eq $base ? "selected" : "";
                           $mh .= "<option value=\"$e->{home}\" $s>$e->{title}</option>";
                        }
                        $mh .= "</select>";
                     }
                  }
               }
               unless($self->{no_search}) {
                  $mh .= "<span class=zim_search><img style=\"height:1em;opacity:0.5;vertical-align:middle\" src=\"data:image/x-png;base64,iVBORw0KGgoAAAANSUhEUgAAAB4AAAAfCAYAAADwbH0HAAAABHNCSVQICAgIfAhkiAAAAAlwSFlzAAABUAAAAVAB++UihAAAABl0RVh0U29mdHdhcmUAd3d3Lmlua3NjYXBlLm9yZ5vuPBoAAALISURBVEiJvZdNaxNBGMd/eVsKgbQqgZgXkoOtIK2ol0jZHnIRc/DQgl9BPTWR4ifwIgiK19Iv4G0Jgm8t6KWSYGlpD9Xira4bGltCsKWRxvGQbJlO87KblP7hOfxnZ+Y3z+yzs7seeusKMA3cAeKt8AA/W/EBMIAtB3M50o3WpMJhLAK3BgH6gBdAwwXUjgbwCvD3gngUHwJeA3flRq/Xy+TkJOl0mlgsBoBpmpRKJZaXl2k0Guq8i8B9oOo007dyBpqmidnZWWFZluikcrks8vm80DRNzf6jk8wBnssDE4mEWF1d7QhUtba2JpLJpAp/2Qs6gXRPE4mEME3TMdSWZVkilUqp9/xmN/AbeXtXVlZcQ+XMh4aGZPi7TtCUvD25XK5vqK25uTl1y6+2A+ftDj6fr2shOdXOzo7w+/0y+Ek78HEl67o+MNRWJpNRD5cT8gJJ2+i63q0OXGlqakq2qXbgqG3sw+EsFI1GT9h24IBtAoGAer1vaZomW3+LdQJcto1lWWcGNk1TthbwTwUf91hfXz8zsDLXr3Z9ntKqvmAwKA4ODgau6MPDQxEKheSqfqZCvUDBNvv7+8zPzw+c7cLCArVaTW4y2vXzABv26sLhsKhUKn1nu7u7KyKRiJztJkphybondRS6rot6ve4aenR0JLLZrHpcTvfaoffygGw2K6rVqmNorVYTExMTKnSJ0x8bp3QJ+CEPHB0dFYZh9IQWCgUxNjamQv8C1zvB1NVca2UelxvHx8eZmZkhnU4Tj8fxeDxsb29TLBYxDKPbY7gFZOjwOKm6DBSV1buJP4r/1prTkTQgB1RcAH8Dj4GLwCfl2nc3cIBh4AHNV2e9DaxO8wvjITAijQsCnwfJXJYfiAFp4DbNOuj2VgkBXxT4JhDpB+5Ww5yulw0gfB7wEaCkwJfOA2zDv0rgvfMCA1yg+RO4Bzz6D/yDum4lIeaUAAAAAElFTkSuQmCC\">";
                  $mh .= "<input class=zim_search_input id=_zim_search_q onchange=\"_zim_search()\" default=\"search\"></span><span id=_zim_results_hint></span>";
               }
               $mh .= "</div>";
               $mh .= "<div id=_zim_results class=zim_results></div>";
               # -- alter <body>
               $body =~ s#<body([^>]*)>#<body$1>$mh#i;
               # -- alter <head>
               $mh = '';
               $mh = "<link rel=\"shortcut icon\" href=\"/$base/-/favicon\">" if($self->{catalog});
               $body =~ s#</head>#$mh</head>#i;
            }
            
            if($me->error()) {
               $status = 404;
               $body = "<html><head><title>404 file not found</title></head><body><h1>404 file not found</h1>"
                  .$me->error(1)
                  ."</body></html>";
               $mime = 'text/html';
            }
         }

         my $sz = length($body);

         my $m = join("\r\n",
            "HTTP/1.1 $status OK",
            "Connection: Keep-Alive",
            "Keep-Alive: timeout=30",
            "Content-Type: $mime",
            "Content-Length: $sz",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Allow-Origin: *",     # -- CORS, allow XHR to make requests
            @header ? (@header,"") : "",
            $body);
         send($cs, $m, 0) || last;
         
      } elsif($http_header =~  /^(PUT|OPTIONS) (.+) HTTP\/1\./){
         my $m = join("\r\n",
            "HTTP/1.1 200 OK",
            "Connection: Keep-Alive",
            "Keep-Alive: timeout=30",
            "Content-Length: 0",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Allow-Origin: *",     # -- CORS, allow XHR to make requests
            "");
         send($cs, $m, 0) || last;
         
      } else {
         print "ERR: #$$: unsupported HTTP request '$http_header'\n" if($http_header && $self->{verbose});
         last;
      }
   }
   shutdown($cs,2);
   close($fh) if($fh);
   exit 0;
}

sub fnum3 {  # -- 10000000 -> 10,000,000
   return reverse join ',', unpack '(A3)*', reverse $_[0]
}

sub timeout {
   my($t,$f) = @_;
   return eval {
      local $SIG{ALRM} = sub { die "timeout $t reached\n" };
      alarm($t);
      &$f();
      alarm 0;
      return 0;
   };
   return -1;
}

1;
