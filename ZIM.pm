package ZIM;

# == ZIM.pm ==
#    based on zimHttpServer.pl written by Pedro González (2012/04/06)
#    turned into ZIM.pm by Rene K. Mueller (2020/03/28) with enhancements as listed below
#
# Description:
#   provides basic OO interface to ZIM files as provided by kiwix.org
#
# History:
# 2020/03/31: 0.0.8: preliminary 64bit cluster size support to support large fulltext indexes (>4GB), improved server() web-gui supporting library (multiple zim files)
# 2020/03/30: 0.0.7: support large article extraction direct to file (without large memory consumption) for wikipedia.zim xapian indices
# 2020/03/30: 0.0.6: preliminary support for library (multiple zim) for server()
# 2020/03/30: 0.0.5: renaming methods: article(url) and articleById(n)
# 2020/03/30: 0.0.4: further code clean up, REST: enable CORS by default, offset & limit considered
# 2020/03/29: 0.0.3: server() barely functional
# 2020/03/29: 0.0.2: fts() with kiwix full text xapian-based indexes (fts and title) support
# 2020/03/28: 0.0.1: initial version, just using zimHttpServer.pl and objectivy it step by step, added info() to return header plus some additional info

our $NAME = "ZIM";
our $VERSION = '0.0.8';

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
   no strict;
   
   bless($self,$class);

   foreach my $k (keys %$arg) {
      $self->{$k} = $arg->{$k};
   }

   @{$self->{error}} = ();

   if($arg->{library}) {                       
      foreach my $f (@{$arg->{library}}) {
         my $b = $f; $b =~ s/\.zim$//;
         print "INF: #$$: library: adding $b ($f)\n" if($self->{verbose});
         $self->{catalog}->{$b} = new ZIM({file=>$f});
         my $me = $self->{catalog}->{$b};
         $me->entry($me->{header}->{mainPage});
         $home = "/$b/".$me->{article}->{namespace}."/".$me->{article}->{url};
         $title = $me->article("/M/Title") || $me->article("/M/Creator") || $e;
         push(@{$self->{_catalog}},{ base=>$b, home=>$home, title=>$title, meta=>$me->{header} });
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
   $me->entry($me->{header}->{mainPage});
   $home = "/".$me->{article}->{namespace}."/".$me->{article}->{url};
   $title = $me->article("/M/Title") || $me->article("/M/Creator") || $e;
   push(@{$self->{_catalog}},{ home=>$home, title=>$title, meta=>$me->{header} });

   return $self;
}

sub info {
   my $self = shift;
   return $self->{header};
}

sub error {
   my $self = shift;
   return join("\n",@{$self->{error}});
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
            print STDERR "ZIM.pm: ERR: file too large (".fnum($size)." bytes) to read into memory, rather extract to a file\n";
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
   my $articleNumber = shift;
   my $opts = shift;
   print "INF: #$$: articleById: #$articleNumber\n" if($self->{verbose}>1);
   while(1) {
      my $p = $self->entry($articleNumber);
      #print to_json($self->{article},{pretty=>1,canonical=>1});
      push(@{$self->{error}},"article not found #$articleNumber"), return '' if($p<0);
      if(defined $self->{article}->{"redirect_index"}) {
         $articleNumber = $self->{article}->{"redirect_index"};
      } else {
         return $opts && $opts->{metadataOnly} ? 
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
         print INDEX "/$self->{article}->{namespace}/$self->{article}->{url}\n";
         print "\r$n" if($self->{verbose} && ($n%100) == 0);
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
   
   # -- search index
   print "INF: #$$: searching '$url' in $file\n" if($self->{verbose});
   open(INDEX, "$file");
   while(<INDEX>){
      chop;
      print "INF: #$$: > $_\n" if($self->{verbose});
      if($url) {
         push(@r,$_) if($self->{case_insens} && /$url/i || /$url/);
      } else {
         push(@r,$_);
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
      $self->{error} = [];    # -- in case extraction failed
   }
   if(!-e $file->{title}) {
      print "INF: #$$: extract /X/title/xapian -> $file->{title}\n";
      $self->article("/X/title/xapian",{dest=>$file->{title}});
      $self->{error} = [];    # -- in case extraction failed
   }
   my $file_xapian = $file->{$opts->{index}||'fulltext'};
   print "INF: #$$: Xapian Index $file_xapian\n" if($self->{verbose}>1);
   if(1) {
      my $db = Search::Xapian::Database->new($file_xapian); 
      my $enq = $db->enquire($q);
      print "INF: #$$: Xapian Query: ".$enq->get_query()->get_description()."\n" if($self->{verbose}>1);
      $opts = $opts || { };
      my @r = $enq->matches($opts->{offset}||0,$opts->{limit}||100);
      my @re;
      foreach my $m (@r) {
         my $doc = $m->get_document();
         my $e = { _id => $m->get_docid(), rank => $m->get_rank()+1, score => $m->get_percent()/100, url => "/".$doc->get_data() };
         $self->article($e->{url},{metadataOnly=>1});
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

   while(1) {                # -- keep-alive operation (exit only if we fail to send)
      my $http_header;

      while(1) {             # -- read the http request header
         my $m;
         recv($cs, $m, 1000, 0);
         $http_header .= $m;
         last if(length($m)<1000);
      }

      # -- processing request
      if($http_header =~  /^GET (.+) HTTP\/1.1\r\n/){
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
                     @r = map { $_->{url} = "/$in->{content}$_->{url}"; $_ } @{$self->{catalog}->{$in->{content}}->fts($in->{q},$in)};
                  } else {
                     foreach my $e (sort keys %{$self->{catalog}}) {
                        my $me = $self->{catalog}->{$e};
                        push(@r,map { $_->{url} = "/$e$_->{url}"; $_ } @{$me->fts($in->{q})});  # -- rebase
                     }
                     @r = sort { $b->{score} <=> $a->{score} } @r;      # -- sort according score (merge all results)
                     my $r = 0;
                     @r = map { $_->{rank} = $r++; $_ } @r;             # -- rerank
                     @r = splice(@r,$in->{offset},$in->{limit}) if($in->{offset}||$in->{limit});      # -- apply limit & offset
                  }
               } else {
                  @r = @{$self->fts($in->{q},$in)};
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
            my($base,$home,$title);
            my(@cat);
            
            $url =~ s/%(..)/chr(hex($1))/eg;

            if($self->{catalog}) {                       # -- dealing with a catalog, determine which entry
               if($url =~ s/\/([\w\-]+)\//\//) {
                  $base = $1;
                  if($self->{catalog}->{$base}) {
                     $me = $self->{catalog}->{$base};
                  } else {
                     push(@{$self->{error}},"unknown catalog entry '$base'");
                     $body = "unknown catalog entry";
                  }
               } else {                                  # -- provide overview of items in catalog
                  $body = "<html><head><title>Catalog</title></head><style>html{font-family:Helvetica,Sans;margin:0;padding:0}body{background:#ddd;margin:1.5em 3em}.icon{vertical-align:middle;height:1.5em}a,a:visited{color:#444;text-decoration:none}.entry{font-size:1.5em;width:20%;display:inline-block;margin:0.5em 1em;border:1px solid #ccc;border-radius:0.3em;padding:0.3em 0.6em;background:#fff;box-shadow:0 0 0.5em 0.1em #888}.entry:hover{box-shadow: 0 0 0.5em 0.1em #55c}.catalog{text-align:center}.meta{margin:0.3em 0;font-size:0.5em;opacity:0.8}.id{font-size:0.8em;opacity:0.5}.footer{text-align:center;margin-top:3em;font-size:0.8em;opacity:0.7}</style><body><div class=catalog>";
                  foreach my $e (@{$self->{_catalog}}) {
                     my $meta = fnum($e->{meta}->{articleCount}) . " articles".
                        "<div class=id>$e->{base} (".fnum(int($e->{meta}->{filesize}/1024/1024))." MiB)</div>";
                     $body .= "<a href=\"$e->{home}\"><span class=entry><img class=icon src=\"/$e->{base}/-/favicon\"> $e->{title}<div class=meta>$meta</div></span></a>";
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
         
            $body = $body || $me->article($url);
            $mime = $mime || ($me->{article}->{mimetype} >= 0 ? $me->{mime}->[$me->{article}->{mimetype}] : "text/plain");

            if(1 && $mime eq 'text/html') {    # -- we need to change/tamper the HTML ...
               my $mh = "";
               $mh .= "<style>body{margin-top:3em !important}.zim_header{z-index:1000;position:fixed;width:100%;padding:0.3em 10em;background:#ddd;box-shadow:0 0 0.5em 0.1em #888;top:0;left:0;text-decoration:none}.zim_entry{background:#eee;margin:0 0.3em;padding:0.3em 0.6em;border:1px solid #ccc;border-radius:0.3em;text-decoration:none;color:#226}.zim_entry:hover{background:#eee}.zim_entry.selected{background:#eef}.zim_search{margin:0 0.5em;padding:0.2em 0.3em;background:#ffc;border:1px solid #aa8;border-radius:0.3em;}.zim_results{z-index:200;display:none;margin:1em 4em;padding:1em 2em;background:#fff}.zim_results.active{display:block}#_zim_results_hint{font-size:0.8em;opacity:0.7}</style>";
               $mh .= "<script>
var _zim_base = \"$base\";
function _zim_search() {
   var q = document.getElementById('_zim_search_q').value;
   var xhr = new XMLHttpRequest();
   document.getElementById('_zim_results_hint').innerHTML = 'searching ...';
   var id = document.getElementById('_zim_results');
   id.innerHTML = '...';
   xhr.onload = function() {
      if(xhr.status >= 200 && xhr.status < 300) {
         //console.log(xhr.responseText);
         var data = JSON.parse(xhr.responseText);
         console.log(data);
         if(data.results.hits.length>0)
            id.classList.toggle('active',true);
         var o = '';
         //id.innerHTML = JSON.stringify(data);
         if(data && data.results && data.results.hits) {
            document.getElementById('_zim_results_hint').innerHTML = data.results.hits.length + ' results';
            for(var e of data.results.hits) {
               if(e.title.length==0) {
                  e.title = e.url.replace(/.*\\//,'');
               }
               o += '<a href=\"' + e.url + '\">' + e.title + '</a><br>';
            }
            id.innerHTML = o;
         } else {
            document.getElementById('_zim_results_hint').innerHTML = 'search failed';
         }
      }
   };
   var p = { q: q };
   xhr.open('GET','/rest?'+Object.keys(p).map(function(k){return k+'='+encodeURIComponent(p[k])}).join('&'));
   xhr.send();
}               
</script>";
               $mh .= "<div class=zim_header>";
               $mh .= "<a href=\"/\"><span class=zim_entry>Home</span></a>";
               if($base) {
                  if($self->{catalog}) {
                     foreach my $e (@{$self->{_catalog}}) {
                        my $s = $e->{base} eq $base ? "selected" : "";
                        $mh .= "<a href=\"$e->{home}\"><span class=\"zim_entry $s\">$e->{title}</span></a>";
                     }
                  }
               }
               unless($self->{no_search}) {
                  $mh .= "<input class=zim_search id=_zim_search_q onchange=\"_zim_search()\" default=\"search\"><span id=_zim_results_hint></span>";
               }
               $mh .= "</div>";
               $mh .= "<div id=_zim_results class=zim_results></div>";
               $body =~ s#<body([^>]*)>#<body$1>$mh#;
            }
            
            if($self->error()) {
               $status = 404;
               $body = "<html><head><title>404 file not found</title></head><body><h1>404 file not found</h1>"
                  .$self->error()
                  ."</body></html>";
               $mime = 'text/html';
               $self->{error} = [];
            }
         }

         my $sz = length($body);

         my $m = join("\r\n",
            "HTTP/1.1 $status OK",
            "Connection: Keep-Alive",
            "Keep-Alive: timeout=30",
            "Content-Type: $mime",
            "Content-Length: $sz",
            "Access-Control-Allow-Headers: *",     # -- CORS, allow XHR to make requests
            @header ? (@header,"") : "",
            $body);
         send($cs, $m, 0) || last;

      } elsif($http_header =~  /^OPTIONS (.+) HTTP\/1.1\r\n/){
         my $m = join("\r\n",
            "HTTP/1.1 200 OK",
            "Connection: Keep-Alive",
            "Keep-Alive: timeout=30",
            "Access-Control-Allow-Headers: *",     # -- CORS, allow XHR to make requests
            "");
         send($cs, $m, 0) || last;
         
      } else {
         last;
      }
   }
   shutdown($cs,2);
   close($fh) if($fh);
   exit 0;
}

sub fnum {
  return reverse join ',', unpack '(A3)*', reverse $_[0]
}
1;
__END__

=pod

*** OUTDATED DOCUMENTATION only applies to previous zimHttpServer.pl (no longer valid for ZIM.pm) ***

=head1 NAME

=head1 SYNOPSIS

	url_pointer

	title_pointer

	entry

	cluster_pointer

	cluster_blob

	articleById

	output_article

=head1 DESCRIPTION

=over 2

=item needs

	it need «xz» program for decompress cluster.
	it use «rm» command.
	it create files in «/tmp/» directory.
	it's tested in Ubuntu and Sabayon operating systems.

=item input

	use:
zim.pl file.zim

	zim.pl can create file.index for search pattern.
	when create file.index, program work very time; be patient.

=item output

socket connect at localhost:8080
	open url "localhost:8080" with web browser

	Temporaly it make files into tmp directory for decompress clusters
/tmp/file_cluster$cluster-pid$$
	it delete these files immediately.

	To create socket require to fork process.
	Because the browser connect five socket simultaneously at "localhost:8080" each one ask a diferent url.

	Note: The son process are terminated and they are found as defunct with ps program. I don't know it.

=back

=head1 METHODS

=over 2

=item url_pointer

	L<url_pointer>

=item title_pointer

	L<title_pointer>

=item entry

	L<entry>

=item cluster_pointer

	L<cluster_pointer>

=item cluster_blob

	L<cluster_blob>

=item articleById

	L<articleById>

=item output_article

	L<output_article>

=item debug

	L<debug>

=back

=head2 header
	%header = (
		"magicNumber" => ZIM\x04,
		"version" => ,
		"uuid" => ,
		"articleCount" => ,
		"clusterCount" => ,
		"urlPtrPos" => ,
		"titlePtrPos" => ,
		"clusterPtrPos" => ,
		"mainPage" => ,
		"checksumPos" => )

=head2 mime

	@mime = (
		"txt/html; charset=utf8",
		"",
		...)

=head2 url_pointer(article_number)

	article_number is sort by url.
	return C<pointer> to article number.

=head2 title_pointer(article_number)

	article_number is sort by title.
	return C<article_number> sort by url.

=head2 entry(article_number)

	article_number is sort by url.
	load in hash %article the entry.
	%article = (
		"number" => article_number,
		"mimetype" => integer, # see L<mimetype>
		"parameter_len" => 0, # no used
		"namespace" => char,
		"revision" => number,
	if(mimetype eq 0xFF)
			"redirect_index" => article_number,
	else
			"cluster_number" => cluster_number,
			"blob_number" => blob_number,
		"url" => string,
		"title" => string)
	

=head2 cluster_pointer(cluster_number)

	return cluster_number_pointer

=head2 cluster_blob(cluster_number, blob_number)

	return data

=head2 articleById(article_number)

	return data

=head2 article(url)

	search the url and return data,
	or search pattern into file.index and return list of item;
	and make file.index if not exist.

	main subrutine of subrutines

	example:
article("/A/wikipedia.html");

	search "/A/wikipedia.html" into file.zim
	return page
	the web browser need other files as file.css file.js image.png
article("/I/favicon");

article("/A/Jordan");
	no found page named /A/Jordan.
	This url start with "/A/" and it start to search.
	It create file.index and search into .zim file,
	which pattern is "Jordan",
	and return list of url which are found with pattern.

article("Jordan");
	no found and return null string.

article("/I/Jordan");
	no found and return null string.

=head2 debug

...

=head1 LICENSE

This program is free software; you may redistribute it and/or modify it under some terms.

=head1 SEE ALSO

=head1 AUTHORS

Original code by Pedro González.
Released 4-6-2012.
yaquitobi@gmail.com
Comment by Pedro, but I'm not english speaker, excuse me my mistakes.

=cut
