NAME=ZIM
VERSION=0.0.1

all::
	@echo "make install deinstall edit backup git changes push pull"

requirements::
	sudo apt -y install libxapian-dev 
	sudo cpan Search::Xapian JSON

install::
	mkdir -p ~/lib/perl5
	cp ZIM.pm ~/lib/perl5/
	cp zim ~/bin/

deinstall::
	rm -f ~lib/perl5/ZIM.pm
	rm -f ~/bin/zim

backup::
	cd ..; tar cfvz ~/Backup/${NAME}-${VERSION}.tar.gz --exclude=*.zim --exclude=*.index --exclude=*xapian ${NAME}; scp ~/Backup/${NAME}-${VERSION}.tar.gz backup:Backup;

edit::
	dee4 zim ZIM.pm Makefile README.md

git::

changes::
	git commit -am "..."

push::

pull::
	git pull
